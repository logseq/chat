package logseq.chat

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.browser.customtabs.CustomTabsIntent
import java.lang.ref.WeakReference
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import logseq.chat.model.LogseqCognitoProviding
import org.json.JSONObject

class CognitoAuthProvider(
    region: String,
    userPoolId: String,
    private val appClientId: String,
    private val oauthDomain: String,
    private val redirectURI: String,
    private val logoutURI: String,
    private val scopes: skip.lib.Array<String>
) : LogseqCognitoProviding {
    init {
        require(region.isNotBlank() && userPoolId.isNotBlank() && appClientId.isNotBlank()) {
            "Cognito Hosted UI is not configured"
        }
    }

    override suspend fun accessToken(): String? {
        val current = loadTokens() ?: return null
        if (current.expiresAtMillis - System.currentTimeMillis() > refreshLeewayMillis) {
            return current.accessToken
        }
        return try {
            val refreshed = tokenRequest(
                mapOf(
                    "grant_type" to "refresh_token",
                    "client_id" to appClientId,
                    "refresh_token" to current.refreshToken
                ),
                previousRefreshToken = current.refreshToken
            )
            saveTokens(refreshed)
            refreshed.accessToken
        } catch (error: Throwable) {
            clearTokens()
            throw error
        }
    }

    override suspend fun signIn(): String {
        val activity = currentActivity.get()
            ?: throw IllegalStateException("The sign-in window is not available")
        val state = randomURLSafeString(24)
        val verifier = randomURLSafeString(64)
        val challenge = base64URL(
            MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(StandardCharsets.UTF_8))
        )
        val authorizationCode = suspendCancellableCoroutine<String> { continuation ->
            synchronized(callbackLock) {
                if (pendingLogin != null) {
                    continuation.resumeWithException(
                        IllegalStateException("A sign-in request is already active")
                    )
                    return@suspendCancellableCoroutine
                }
                pendingLogin = PendingLogin(state, continuation)
            }
            continuation.invokeOnCancellation {
                synchronized(callbackLock) {
                    if (pendingLogin?.continuation === continuation) pendingLogin = null
                }
            }
            val authorizationURL = endpoint("/oauth2/authorize") + "?" + formEncoded(
                mapOf(
                    "response_type" to "code",
                    "client_id" to appClientId,
                    "redirect_uri" to redirectURI,
                    "scope" to scopes.joinToString(" "),
                    "state" to state,
                    "code_challenge" to challenge,
                    "code_challenge_method" to "S256"
                )
            )
            activity.runOnUiThread {
                try {
                    CustomTabsIntent.Builder().build().launchUrl(activity, Uri.parse(authorizationURL))
                } catch (error: Throwable) {
                    synchronized(callbackLock) { pendingLogin = null }
                    if (continuation.isActive) continuation.resumeWithException(error)
                }
            }
        }
        val tokens = tokenRequest(
            mapOf(
                "grant_type" to "authorization_code",
                "client_id" to appClientId,
                "code" to authorizationCode,
                "redirect_uri" to redirectURI,
                "code_verifier" to verifier
            ),
            previousRefreshToken = null
        )
        require(tokens.refreshToken.isNotBlank()) { "Cognito did not return a refresh token" }
        saveTokens(tokens)
        return tokens.accessToken
    }

    override suspend fun signOut() {
        val refreshToken = loadTokens()?.refreshToken
        clearTokens()
        if (!refreshToken.isNullOrBlank()) {
            runCatching {
                tokenPost(
                    endpoint("/oauth2/revoke"),
                    mapOf("client_id" to appClientId, "token" to refreshToken)
                )
            }
        }
    }

    private suspend fun tokenRequest(
        values: Map<String, String>,
        previousRefreshToken: String?
    ): StoredTokens {
        val response = tokenPost(endpoint("/oauth2/token"), values)
        val accessToken = response.optString("access_token")
        require(accessToken.isNotBlank()) { "Cognito did not return an access token" }
        val refreshToken = response.optString("refresh_token").ifBlank {
            previousRefreshToken.orEmpty()
        }
        val expiresIn = response.optLong("expires_in", 3600)
        return StoredTokens(
            accessToken = accessToken,
            refreshToken = refreshToken,
            expiresAtMillis = System.currentTimeMillis() + expiresIn * 1000
        )
    }

    private suspend fun tokenPost(url: String, values: Map<String, String>): JSONObject =
        withContext(Dispatchers.IO) {
            val connection = URL(url).openConnection() as HttpURLConnection
            try {
                connection.requestMethod = "POST"
                connection.connectTimeout = 15_000
                connection.readTimeout = 15_000
                connection.doOutput = true
                connection.setRequestProperty(
                    "Content-Type",
                    "application/x-www-form-urlencoded"
                )
                connection.outputStream.use {
                    it.write(formEncoded(values).toByteArray(StandardCharsets.UTF_8))
                }
                val success = connection.responseCode in 200..299
                val body = (if (success) connection.inputStream else connection.errorStream)
                    ?.bufferedReader()?.use { it.readText() }.orEmpty()
                if (!success) {
                    val reason = runCatching { JSONObject(body).optString("error") }
                        .getOrNull().orEmpty().ifBlank { "HTTP ${connection.responseCode}" }
                    throw IllegalStateException("Cognito token request failed: $reason")
                }
                if (body.isBlank()) JSONObject() else JSONObject(body)
            } finally {
                connection.disconnect()
            }
        }

    private fun saveTokens(tokens: StoredTokens) {
        val json = JSONObject()
            .put("accessToken", tokens.accessToken)
            .put("refreshToken", tokens.refreshToken)
            .put("expiresAtMillis", tokens.expiresAtMillis)
            .toString()
            .toByteArray(StandardCharsets.UTF_8)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, encryptionKey())
        val encrypted = JSONObject()
            .put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .put("ciphertext", Base64.encodeToString(cipher.doFinal(json), Base64.NO_WRAP))
            .toString()
        preferences().edit().putString(tokenPreference, encrypted).apply()
    }

    private fun loadTokens(): StoredTokens? {
        val encrypted = preferences().getString(tokenPreference, null) ?: return null
        return runCatching {
            val wrapper = JSONObject(encrypted)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                Cipher.DECRYPT_MODE,
                encryptionKey(),
                GCMParameterSpec(128, Base64.decode(wrapper.getString("iv"), Base64.NO_WRAP))
            )
            val json = JSONObject(
                String(
                    cipher.doFinal(Base64.decode(wrapper.getString("ciphertext"), Base64.NO_WRAP)),
                    StandardCharsets.UTF_8
                )
            )
            StoredTokens(
                accessToken = json.getString("accessToken"),
                refreshToken = json.getString("refreshToken"),
                expiresAtMillis = json.getLong("expiresAtMillis")
            )
        }.getOrElse {
            clearTokens()
            null
        }
    }

    private fun clearTokens() {
        preferences().edit().remove(tokenPreference).apply()
    }

    private fun preferences() = applicationContext.getSharedPreferences(
        "logseq-cognito-auth",
        Context.MODE_PRIVATE
    )

    private fun encryptionKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(keyAlias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                keyAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return generator.generateKey()
    }

    private fun endpoint(path: String) = "https://$oauthDomain$path"

    private data class StoredTokens(
        val accessToken: String,
        val refreshToken: String,
        val expiresAtMillis: Long
    )

    companion object {
        private const val refreshLeewayMillis = 60_000L
        private const val tokenPreference = "tokens"
        private const val keyAlias = "com.logseq.chat.cognito.tokens"
        private val random = SecureRandom()
        private val callbackLock = Any()
        private lateinit var applicationContext: Context
        private var currentActivity = WeakReference<Activity>(null)
        private var pendingLogin: PendingLogin? = null

        fun initialize(context: Context) {
            applicationContext = context.applicationContext
        }

        fun attachActivity(activity: Activity) {
            currentActivity = WeakReference(activity)
        }

        fun detachActivity(activity: Activity) {
            if (currentActivity.get() === activity) currentActivity.clear()
        }

        fun handleCallback(url: String?): Boolean {
            if (url.isNullOrBlank()) return false
            val uri = Uri.parse(url)
            if (!uri.scheme.equals("logseqchat", ignoreCase = true) ||
                !uri.host.equals("auth", ignoreCase = true) || uri.path != "/callback") {
                return false
            }
            val pending = synchronized(callbackLock) {
                pendingLogin.also { pendingLogin = null }
            } ?: return true
            if (!pending.continuation.isActive) return true
            val callbackState = uri.getQueryParameter("state")
            when {
                callbackState != pending.state -> pending.continuation.resumeWithException(
                    IllegalStateException("The sign-in response could not be verified")
                )
                !uri.getQueryParameter("error").isNullOrBlank() ->
                    pending.continuation.resumeWithException(
                        IllegalStateException("Sign-in failed: ${uri.getQueryParameter("error")}")
                    )
                uri.getQueryParameter("code").isNullOrBlank() ->
                    pending.continuation.resumeWithException(
                        IllegalStateException("Cognito did not return an authorization code")
                    )
                else -> pending.continuation.resume(uri.getQueryParameter("code")!!)
            }
            return true
        }

        private fun randomURLSafeString(byteCount: Int): String {
            val bytes = ByteArray(byteCount)
            random.nextBytes(bytes)
            return base64URL(bytes)
        }

        private fun base64URL(bytes: ByteArray): String =
            Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

        private fun formEncoded(values: Map<String, String>): String = values.entries
            .sortedBy { it.key }
            .joinToString("&") {
                "${encode(it.key)}=${encode(it.value)}"
            }

        private fun encode(value: String): String =
            URLEncoder.encode(value, StandardCharsets.UTF_8.name())

        private data class PendingLogin(
            val state: String,
            val continuation: CancellableContinuation<String>
        )
    }
}
