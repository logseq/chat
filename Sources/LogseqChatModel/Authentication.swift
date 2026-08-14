import Foundation
import Observation

public protocol LogseqCognitoProviding: Sendable {
    func accessToken() async throws -> String?
    func signIn(username: String, password: String) async throws -> String
    func signOut() async throws
}

public enum LogseqAuthenticationState: String, Sendable {
    case restoring
    case signedOut
    case signingIn
    case signedIn
    case signingOut
}

public enum LogseqAuthenticationError: Error, LocalizedError {
    case invalidCredentials
    case notSignedIn

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Enter your email and password."
        case .notSignedIn:
            return "Sign in to connect to Logseq Sync."
        }
    }
}

@MainActor @Observable public final class LogseqAuthenticationStore {
    public private(set) var state: LogseqAuthenticationState = .restoring
    public private(set) var errorMessage: String?

    private let provider: any LogseqCognitoProviding
    private let onAccessToken: @MainActor (String?) -> Void

    public init(
        provider: any LogseqCognitoProviding,
        onAccessToken: @escaping @MainActor (String?) -> Void = { _ in }
    ) {
        self.provider = provider
        self.onAccessToken = onAccessToken
    }

    public func restore() async {
        state = .restoring
        errorMessage = nil
        do {
            guard let token = try await provider.accessToken(), !token.isEmpty else {
                state = .signedOut
                onAccessToken(nil)
                return
            }
            state = .signedIn
            onAccessToken(token)
        } catch {
            state = .signedOut
            errorMessage = error.localizedDescription
            onAccessToken(nil)
        }
    }

    public func signIn(username: String, password: String) async {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else {
            errorMessage = LogseqAuthenticationError.invalidCredentials.localizedDescription
            return
        }
        state = .signingIn
        errorMessage = nil
        do {
            let token = try await provider.signIn(username: username, password: password)
            guard !token.isEmpty else {
                throw LogseqAuthenticationError.notSignedIn
            }
            state = .signedIn
            onAccessToken(token)
        } catch {
            state = .signedOut
            errorMessage = error.localizedDescription
            onAccessToken(nil)
        }
    }

    public func signOut() async {
        state = .signingOut
        errorMessage = nil
        do {
            try await provider.signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
        state = .signedOut
        onAccessToken(nil)
    }

    public func accessToken() async throws -> String {
        do {
            guard let token = try await provider.accessToken(), !token.isEmpty else {
                state = .signedOut
                errorMessage = LogseqAuthenticationError.notSignedIn.localizedDescription
                onAccessToken(nil)
                throw LogseqAuthenticationError.notSignedIn
            }
            state = .signedIn
            errorMessage = nil
            onAccessToken(token)
            return token
        } catch {
            state = .signedOut
            errorMessage = error.localizedDescription
            onAccessToken(nil)
            throw error
        }
    }
}
