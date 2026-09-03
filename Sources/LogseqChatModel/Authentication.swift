import Foundation
import Observation

public protocol LogseqCognitoProviding: Sendable {
    func accessToken() async throws -> String?
    func signIn() async throws -> String
    func signOut() async throws
}

public enum LogseqAuthenticationState: String, Sendable {
    case restoring
    case signedOut
    case signingIn
    case signedIn
    case signingOut
}

public enum LogseqAuthenticationError: Error, LocalizedError, Equatable {
    case notSignedIn

    public var errorDescription: String? {
        switch self {
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
        } catch is LogseqAuthenticationError {
            state = .signedOut
            onAccessToken(nil)
        } catch {
            state = .signedOut
            errorMessage = Self.displayedMessage(for: error)
            onAccessToken(nil)
        }
    }

    public func signIn() async {
        state = .signingIn
        errorMessage = nil
        do {
            let token = try await provider.signIn()
            guard !token.isEmpty else {
                throw LogseqAuthenticationError.notSignedIn
            }
            state = .signedIn
            onAccessToken(token)
        } catch {
            state = .signedOut
            errorMessage = Self.displayedMessage(for: error)
            onAccessToken(nil)
        }
    }

    public func signOut() async {
        state = .signingOut
        errorMessage = nil
        do {
            try await provider.signOut()
        } catch {
            errorMessage = Self.displayedMessage(for: error)
        }
        state = .signedOut
        onAccessToken(nil)
    }

    public func accessToken() async throws -> String {
        do {
            guard let token = try await provider.accessToken(), !token.isEmpty else {
                state = .signedOut
                errorMessage = nil
                onAccessToken(nil)
                throw LogseqAuthenticationError.notSignedIn
            }
            state = .signedIn
            errorMessage = nil
            onAccessToken(token)
            return token
        } catch is LogseqAuthenticationError {
            state = .signedOut
            errorMessage = nil
            onAccessToken(nil)
            throw LogseqAuthenticationError.notSignedIn
        } catch {
            state = .signedOut
            errorMessage = Self.displayedMessage(for: error)
            onAccessToken(nil)
            throw error
        }
    }

    private static func displayedMessage(for error: Error) -> String {
        if let authenticationError = error as? LogseqAuthenticationError {
            return authenticationError.errorDescription ?? "Sign in to connect to Logseq Sync."
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        let description = error.localizedDescription
        if description.contains("$") || description.contains("Case") {
            return "Something went wrong. Try signing in again."
        }
        return description
    }
}
