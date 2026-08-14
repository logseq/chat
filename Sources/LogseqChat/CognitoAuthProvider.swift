// SKIP SYMBOLFILE

import Foundation
import LogseqChatModel

#if os(iOS)
@preconcurrency import AWSCore
@preconcurrency import AWSCognitoIdentityProvider
#endif

enum CognitoAuthProviderError: Error, LocalizedError {
    case missingConfiguration
    case missingAccessToken

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "The native Cognito app client is not configured."
        case .missingAccessToken:
            return "Cognito did not return an access token."
        }
    }
}

actor CognitoAuthProvider: LogseqCognitoProviding {
    #if os(iOS)
    private let userPool: AWSCognitoIdentityUserPool?

    init(region: String, userPoolId: String, appClientId: String) {
        guard !region.isEmpty, !userPoolId.isEmpty, !appClientId.isEmpty else {
            self.userPool = nil
            return
        }
        let configuration = AWSCognitoIdentityUserPoolConfiguration(
            clientId: appClientId,
            clientSecret: nil,
            poolId: userPoolId
        )
        let key = "logseq-chat-\(region)-\(userPoolId)-\(appClientId)"
        AWSCognitoIdentityUserPool.registerCognitoIdentityUserPool(
            with: configuration,
            forKey: key
        )
        self.userPool = AWSCognitoIdentityUserPool(forKey: key)
    }

    func accessToken() async throws -> String? {
        guard let userPool else { throw CognitoAuthProviderError.missingConfiguration }
        guard let user = userPool.currentUser() else { return nil }
        let session: AWSCognitoIdentityUserSession = try await value(from: user.getSession())
        return session.accessToken?.tokenString
    }

    func signIn(username: String, password: String) async throws -> String {
        guard let userPool else { throw CognitoAuthProviderError.missingConfiguration }
        let user = userPool.getUser(username)
        let session: AWSCognitoIdentityUserSession = try await value(
            from: user.getSession(username, password: password, validationData: nil)
        )
        guard let token = session.accessToken?.tokenString, !token.isEmpty else {
            throw CognitoAuthProviderError.missingAccessToken
        }
        return token
    }

    func signOut() async throws {
        guard let userPool else { throw CognitoAuthProviderError.missingConfiguration }
        userPool.currentUser()?.signOutAndClearLastKnownUser()
    }

    private func value<Result>(from task: AWSTask<Result>) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            task.continueWith { completedTask in
                if let error = completedTask.error {
                    continuation.resume(throwing: error)
                } else if let result = completedTask.result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: CognitoAuthProviderError.missingAccessToken)
                }
                return nil
            }
        }
    }
    #else
    init(region: String, userPoolId: String, appClientId: String) {
    }

    func accessToken() async throws -> String? {
        throw CognitoAuthProviderError.missingConfiguration
    }

    func signIn(username: String, password: String) async throws -> String {
        throw CognitoAuthProviderError.missingConfiguration
    }

    func signOut() async throws {
        throw CognitoAuthProviderError.missingConfiguration
    }
    #endif
}
