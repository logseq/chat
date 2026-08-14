package logseq.chat

import android.content.Context
import com.amazonaws.mobileconnectors.cognitoidentityprovider.CognitoDevice
import com.amazonaws.mobileconnectors.cognitoidentityprovider.CognitoUserPool
import com.amazonaws.mobileconnectors.cognitoidentityprovider.CognitoUserSession
import com.amazonaws.mobileconnectors.cognitoidentityprovider.continuations.AuthenticationContinuation
import com.amazonaws.mobileconnectors.cognitoidentityprovider.continuations.AuthenticationDetails
import com.amazonaws.mobileconnectors.cognitoidentityprovider.continuations.ChallengeContinuation
import com.amazonaws.mobileconnectors.cognitoidentityprovider.continuations.MultiFactorAuthenticationContinuation
import com.amazonaws.mobileconnectors.cognitoidentityprovider.handlers.AuthenticationHandler
import com.amazonaws.regions.Regions
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import logseq.chat.model.LogseqCognitoProviding

class CognitoAuthProvider(
    private val region: String,
    private val userPoolId: String,
    private val appClientId: String
) : LogseqCognitoProviding {
    private val userPool: CognitoUserPool by lazy {
        require(region.isNotBlank() && userPoolId.isNotBlank() && appClientId.isNotBlank()) {
            "The native Cognito app client is not configured"
        }
        CognitoUserPool(
            requireNotNull(context) { "Cognito provider was not initialized" },
            userPoolId,
            appClientId,
            null,
            Regions.fromName(region)
        )
    }

    override suspend fun accessToken(): String? {
        val session = session(username = null, password = null) ?: return null
        return session.accessToken?.jwtToken
            ?: throw IllegalStateException("Cognito did not return an access token")
    }

    override suspend fun signIn(username: String, password: String): String {
        val session = session(username, password)
            ?: throw IllegalStateException("Cognito did not return a user session")
        return session.accessToken?.jwtToken
            ?: throw IllegalStateException("Cognito did not return an access token")
    }

    override suspend fun signOut() {
        userPool.currentUser.signOut()
    }

    private suspend fun session(username: String?, password: String?): CognitoUserSession? =
        suspendCancellableCoroutine { continuation ->
            val user = if (username == null) userPool.currentUser else userPool.getUser(username)
            user.getSessionInBackground(object : AuthenticationHandler {
                override fun onSuccess(session: CognitoUserSession, device: CognitoDevice?) {
                    if (continuation.isActive) continuation.resume(session)
                }

                override fun getAuthenticationDetails(
                    authenticationContinuation: AuthenticationContinuation,
                    userId: String?
                ) {
                    if (username == null || password == null) {
                        if (continuation.isActive) continuation.resume(null)
                        return
                    }
                    authenticationContinuation.setAuthenticationDetails(
                        AuthenticationDetails(username, password, null)
                    )
                    authenticationContinuation.continueTask()
                }

                override fun getMFACode(continuation: MultiFactorAuthenticationContinuation) {
                    failUnsupportedChallenge()
                }

                override fun authenticationChallenge(continuation: ChallengeContinuation) {
                    failUnsupportedChallenge()
                }

                override fun onFailure(error: Exception) {
                    if (continuation.isActive) continuation.resumeWithException(error)
                }

                private fun failUnsupportedChallenge() {
                    if (continuation.isActive) {
                        continuation.resumeWithException(
                            IllegalStateException("This account requires an additional sign-in challenge")
                        )
                    }
                }
            })
        }

    companion object {
        private var context: Context? = null

        fun initialize(context: Context) {
            this.context = context.applicationContext
        }
    }
}
