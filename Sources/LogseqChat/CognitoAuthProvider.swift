// SKIP SYMBOLFILE

import Foundation
import LogseqChatModel

#if !SKIP && AppleAuth
import Amplify
import AWSCognitoAuthPlugin
#endif

enum CognitoAuthProviderError: Error, LocalizedError {
    case incompleteSignIn
    case missingAccessToken

    var errorDescription: String? {
        switch self {
        case .incompleteSignIn:
            return "Cognito requires another authentication step."
        case .missingAccessToken:
            return "Cognito did not return an access token."
        }
    }
}

actor CognitoAuthProvider: LogseqCognitoProviding {
    init(region: String, userPoolId: String, appClientId: String) {
    }

    func accessToken() async throws -> String? {
        #if !SKIP && AppleAuth
        let session = try await Amplify.Auth.fetchAuthSession()
        #if DEBUG
        print("LogseqChat debug: Amplify session fetched signedIn=\(session.isSignedIn)")
        #endif
        guard session.isSignedIn else { return nil }
        guard let cognitoSession = session as? AWSAuthCognitoSession else {
            #if DEBUG
            print("LogseqChat debug: Amplify session has no Cognito token provider")
            #endif
            throw CognitoAuthProviderError.missingAccessToken
        }
        let tokens = try cognitoSession.userPoolTokensResult.get()
        guard !tokens.accessToken.isEmpty else {
            throw CognitoAuthProviderError.missingAccessToken
        }
        #if DEBUG
        print("LogseqChat debug: Cognito access token is available")
        #endif
        return tokens.accessToken
        #else
        throw CognitoAuthProviderError.missingAccessToken
        #endif
    }

    func signIn(username: String, password: String) async throws -> String {
        #if !SKIP && AppleAuth
        let result = try await Amplify.Auth.signIn(username: username, password: password)
        guard result.isSignedIn else {
            throw CognitoAuthProviderError.incompleteSignIn
        }
        guard let token = try await accessToken() else {
            throw CognitoAuthProviderError.missingAccessToken
        }
        return token
        #else
        throw CognitoAuthProviderError.missingAccessToken
        #endif
    }

    func signOut() async throws {
        #if !SKIP && AppleAuth
        _ = await Amplify.Auth.signOut()
        #endif
    }
}
