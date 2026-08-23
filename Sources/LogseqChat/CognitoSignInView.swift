import SwiftUI
import LogseqChatModel

struct CognitoSignInView: View {
    @State var authentication: LogseqAuthenticationStore
    @AppStorage("logseq.appearance") private var appearance = "system"
    @Environment(\.colorScheme) private var colorScheme

    private var palette: LogseqThemePalette {
        LogseqThemePolicy.palette(
            mode: LogseqThemeMode(rawValue: appearance) ?? .system,
            systemIsDark: colorScheme == .dark
        )
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("Logseq")
                .font(.largeTitle.bold())
            Text("Sign in to connect your sync graphs.")
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
            Button {
                Task { await authentication.signIn() }
            } label: {
                if authentication.state == .signingIn {
                    ProgressView()
                } else {
                    Text("Sign in")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(authentication.state == .signingIn)
            .accessibilityIdentifier("button.hosted-sign-in")
            if let errorMessage = authentication.errorMessage, !errorMessage.isEmpty {
                Text(verbatim: errorMessage)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(palette.primaryText)
        .background(palette.background.ignoresSafeArea())
        .tint(LogseqThemePolicy.accent)
    }
}
