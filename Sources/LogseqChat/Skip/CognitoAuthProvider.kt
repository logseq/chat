package logseq.chat

import android.content.Context
import com.amplifyframework.auth.cognito.AWSCognitoAuthPlugin
import com.amplifyframework.auth.cognito.AWSCognitoAuthSession
import com.amplifyframework.core.Amplify
import com.amplifyframework.core.configuration.AmplifyOutputs
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import logseq.chat.model.LogseqCognitoProviding
import org.json.JSONArray
import org.json.JSONObject

class CognitoAuthProvider(
    region: String,
    userPoolId: String,
    appClientId: String
) : LogseqCognitoProviding {
    init {
        require(region.isNotBlank() && userPoolId.isNotBlank() && appClientId.isNotBlank()) {
            "The native Cognito app client is not configured"
        }
    }

    override suspend fun accessToken(): String? =
        suspendCancellableCoroutine { continuation ->
            Amplify.Auth.fetchAuthSession(
                { result ->
                    val session = result as? AWSCognitoAuthSession
                    if (!continuation.isActive) return@fetchAuthSession
                    if (session == null || !session.isSignedIn) {
                        continuation.resume(null)
                    } else {
                        val token = session.userPoolTokensResult.value?.accessToken
                        if (token == null) {
                            continuation.resumeWithException(
                                IllegalStateException("Cognito did not return an access token")
                            )
                        } else {
                            continuation.resume(token)
                        }
                    }
                },
                { error ->
                    if (continuation.isActive) continuation.resumeWithException(error)
                }
            )
        }

    override suspend fun signIn(username: String, password: String): String {
        suspendCancellableCoroutine<Unit> { continuation ->
            Amplify.Auth.signIn(
                username,
                password,
                { result ->
                    if (!continuation.isActive) return@signIn
                    if (result.isSignedIn) {
                        continuation.resume(Unit)
                    } else {
                        continuation.resumeWithException(
                            IllegalStateException("Continue sign-in with Amplify Authenticator")
                        )
                    }
                },
                { error ->
                    if (continuation.isActive) continuation.resumeWithException(error)
                }
            )
        }
        return accessToken() ?: throw IllegalStateException("Cognito did not return an access token")
    }

    override suspend fun signOut() {
        suspendCancellableCoroutine<Unit> { continuation ->
            Amplify.Auth.signOut {
                if (continuation.isActive) continuation.resume(Unit)
            }
        }
    }

    companion object {
        private const val configurationAsset = "logseq/chat/Resources/logseq-auth.json"

        @Volatile
        private var configured = false

        fun initialize(context: Context) {
            synchronized(this) {
                if (configured) return
                val configuration = context.assets.open(configurationAsset)
                    .bufferedReader()
                    .use { JSONObject(it.readText()) }
                val passwordPolicy = JSONObject()
                    .put("min_length", 8)
                    .put("require_lowercase", true)
                    .put("require_numbers", true)
                    .put("require_symbols", true)
                    .put("require_uppercase", true)
                val auth = JSONObject()
                    .put("aws_region", configuration.getString("region"))
                    .put("user_pool_id", configuration.getString("userPoolId"))
                    .put("user_pool_client_id", configuration.getString("appClientId"))
                    .put("password_policy", passwordPolicy)
                    .put("standard_required_attributes", JSONArray().put("email"))
                    .put("user_verification_types", JSONArray().put("email"))
                    .put("unauthenticated_identities_enabled", false)
                val outputs = JSONObject()
                    .put("version", "1.1")
                    .put("auth", auth)

                Amplify.addPlugin(AWSCognitoAuthPlugin())
                Amplify.configure(AmplifyOutputs.fromString(outputs.toString()), context.applicationContext)
                configured = true
            }
        }
    }
}
