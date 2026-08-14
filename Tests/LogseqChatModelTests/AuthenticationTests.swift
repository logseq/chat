import Foundation
import Testing
@testable import LogseqChatModel

private actor FakeCognitoProvider: LogseqCognitoProviding {
    private var token: String?
    private let signInToken: String
    private var signOutCount = 0

    init(token: String?, signInToken: String = "signed-in-access-token") {
        self.token = token
        self.signInToken = signInToken
    }

    func accessToken() async throws -> String? {
        token
    }

    func signIn(username: String, password: String) async throws -> String {
        #expect(username == "user@example.com")
        #expect(password == "correct horse")
        token = signInToken
        return signInToken
    }

    func signOut() async throws {
        token = nil
        signOutCount += 1
    }

    func recordedSignOutCount() -> Int {
        signOutCount
    }
}

@Suite struct AuthenticationTests {
    @Test @MainActor func restoresAndRefreshesAnExistingAccessToken() async throws {
        let provider = FakeCognitoProvider(token: "restored-access-token")
        let auth = LogseqAuthenticationStore(provider: provider)

        await auth.restore()

        #expect(auth.state == .signedIn)
        #expect(try await auth.accessToken() == "restored-access-token")
    }

    @Test @MainActor func signsInAndPublishesOnlyTheAccessToken() async throws {
        let provider = FakeCognitoProvider(token: nil)
        var published: [String] = []
        let auth = LogseqAuthenticationStore(provider: provider) { token in
            if let token {
                published.append(token)
            }
        }

        await auth.signIn(username: " user@example.com ", password: "correct horse")

        #expect(auth.state == .signedIn)
        #expect(published == ["signed-in-access-token"])
        #expect(auth.errorMessage == nil)
    }

    @Test @MainActor func signsOutAndClearsPublishedAuthorization() async throws {
        let provider = FakeCognitoProvider(token: "access-token")
        var published: [String?] = []
        let auth = LogseqAuthenticationStore(provider: provider) { token in
            published.append(token)
        }
        await auth.restore()

        await auth.signOut()

        #expect(auth.state == .signedOut)
        #expect(published == ["access-token", nil])
        #expect(await provider.recordedSignOutCount() == 1)
    }
}
