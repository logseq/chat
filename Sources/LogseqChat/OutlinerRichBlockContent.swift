import SwiftUI
import LogseqChatModel

#if !SKIP
import HighlightSwift
import SwiftUIMath
#if os(iOS)
import AVKit
import UIKit
import WebKit
#endif
#endif

#if SKIP
import android.net.Uri
import android.webkit.WebView
import android.widget.MediaController
import android.widget.VideoView
import androidx.compose.ui.viewinterop.AndroidView
import com.agog.mathdisplay.MTMathView
import dev.hossain.highlight.ui.HighlightThemeProvider
import dev.hossain.highlight.ui.SyntaxHighlightedCode
#endif

struct OutlinerRichBlockContent: View {
    let node: LogseqMarkupNode
    let youtubeStartSeconds: Int?
    let onSeekYouTube: (String, Int) -> Void
    let onOpenMarkupLink: (OutlinerMarkupLink) -> Void

    @ViewBuilder var body: some View {
        Group {
            switch node.type {
            case .quote:
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: 3)
                    quoteText
                        .italic()
                        .foregroundStyle(.secondary)
                }
            case .math:
                NativeLatexView(
                    expression: node.text ?? "",
                    isDisplay: node.style != "inline"
                )
            case .codeBlock:
                SyntaxHighlightedCodeBlock(
                    code: node.text ?? "",
                    language: node.style
                )
            case .video:
                EmbeddedVideo(
                    url: EmbeddedMediaPolicy.safeURL(node.url),
                    startSeconds: youtubeStartSeconds
                )
            case .iframe:
                EmbeddedWebContent(url: EmbeddedMediaPolicy.safeURL(node.url))
            case .youtubeTimestamp:
                YouTubeTimestamp(
                    label: node.text ?? "",
                    url: node.url,
                    seconds: OutlinerYouTubeTimestampPolicy.seconds(node),
                    onSeek: onSeekYouTube
                )
            case .cloze:
                InteractiveCloze(text: node.text ?? "")
            default:
                Text(verbatim: node.text ?? node.url ?? "")
            }
        }
        .accessibilityIdentifier(contentAccessibilityIdentifier)
    }

    private var contentAccessibilityIdentifier: String {
        if let youtubeStartSeconds {
            switch node.type {
            case .video:
                return "block.rich.video.start.\(youtubeStartSeconds)"
            case .youtubeTimestamp:
                return "block.rich.youtubeTimestamp.start.\(youtubeStartSeconds)"
            default:
                break
            }
        }
        return "block.rich.\(node.type.rawValue)"
    }

    @ViewBuilder private var quoteText: some View {
        #if !SKIP
        Text(OutlinerMarkupAttributedString.make(nodes: node.children, fallback: ""))
            .environment(\.openURL, OpenURLAction { url in
                guard let link = OutlinerMarkupLink(url: url) else { return .systemAction }
                onOpenMarkupLink(link)
                return .handled
            })
        #else
        let presentation = OutlinerMarkupPresentation.make(
            nodes: node.children,
            fallback: ""
        )
        Text(verbatim: presentation.plainText)
        #endif
    }
}

private struct YouTubeTimestamp: View {
    let label: String
    let url: String?
    let seconds: Int?
    let onSeek: (String, Int) -> Void

    @ViewBuilder
    var body: some View {
        if let url, let seconds {
            Button {
                onSeek(url, seconds)
            } label: {
                timestampLabel
                    .foregroundStyle(.tint)
                    .platformTimestampHitShape()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Seek YouTube video to " + label)
        } else {
            timestampLabel.foregroundStyle(.secondary)
        }
    }

    private var timestampLabel: some View {
        Text(verbatim: "◷ " + label)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    @ViewBuilder func platformTimestampHitShape() -> some View {
        #if !SKIP
        contentShape(Rectangle())
        #else
        self
        #endif
    }
}

private struct InteractiveCloze: View {
    let text: String
    @State private var isRevealed = false

    var body: some View {
        Button {
            isRevealed.toggle()
        } label: {
            Text(verbatim: isRevealed ? text : "Tap to reveal")
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRevealed ? text : "Reveal cloze")
    }
}

private struct SyntaxHighlightedCodeBlock: View {
    let code: String
    let language: String?

    private var contentHeight: CGFloat {
        let lineCount = max(code.components(separatedBy: "\n").count, 1)
        return min(max(CGFloat(lineCount * 20 + 34), 72), 320)
    }

    var body: some View {
        #if SKIP
        ComposeView { _ in
            HighlightThemeProvider {
                SyntaxHighlightedCode(
                    code: code,
                    language: language ?? "plaintext"
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: contentHeight)
        #else
        VStack(alignment: .leading, spacing: 6) {
            if let language, !language.isEmpty {
                Text(verbatim: language)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                CodeText(code)
                    .codeTextColors(.theme(.github))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        #endif
    }
}

private struct NativeLatexView: View {
    let expression: String
    let isDisplay: Bool

    var body: some View {
        #if SKIP
        ComposeView { _ in
            AndroidView(
                factory: { context in
                    let view = MTMathView(context)
                    view.latex = expression
                    return view
                },
                update: { view in view.latex = expression }
            )
        }
        .frame(maxWidth: .infinity, minHeight: isDisplay ? 56.0 : 30.0, alignment: .leading)
        #else
        SwiftUIMath.Math(expression)
            .mathTypesettingStyle(isDisplay ? .display : .text)
            .frame(maxWidth: .infinity, minHeight: isDisplay ? 56 : 30, alignment: .leading)
        #endif
    }
}

private struct EmbeddedVideo: View {
    let url: URL?
    let startSeconds: Int?

    @ViewBuilder var body: some View {
        if let url,
           let embedURL = EmbeddedMediaPolicy.webVideoEmbedURL(
            url,
            startSeconds: startSeconds
           ) {
            EmbeddedWebContent(url: embedURL)
        } else if let url {
            #if !SKIP && os(iOS)
            NativeAppleVideo(url: url)
                .frame(height: 220)
            #elseif SKIP
            ComposeView { _ in
                AndroidView(
                    factory: { context in
                        let view = VideoView(context)
                        let controls = MediaController(context)
                        controls.setAnchorView(view)
                        view.setMediaController(controls)
                        view.setVideoURI(Uri.parse(url.absoluteString))
                        view.seekTo(1)
                        return view
                    },
                    update: { view in
                        if view.tag as? String != url.absoluteString {
                            view.tag = url.absoluteString
                            view.setVideoURI(Uri.parse(url.absoluteString))
                            view.seekTo(1)
                        }
                    }
                )
            }
            .frame(height: 220)
            #else
            Link(url.absoluteString, destination: url)
            #endif
        } else {
            Text("Invalid video URL")
                .foregroundStyle(.secondary)
        }
    }
}

#if !SKIP && os(iOS)
private struct NativeAppleVideo: View {
    @State private var player: AVPlayer

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .onDisappear { player.pause() }
    }
}
#endif

private struct EmbeddedWebContent: View {
    let url: URL?

    @ViewBuilder var body: some View {
        if let url {
            #if !SKIP && os(iOS)
            AppleWebView(url: url)
                .frame(height: 240)
            #elseif SKIP
            ComposeView { _ in
                AndroidView(
                    factory: { context in
                        let view = WebView(context)
                        view.settings.javaScriptEnabled = true
                        view.settings.domStorageEnabled = true
                        view.settings.mediaPlaybackRequiresUserGesture = true
                        AndroidEmbeddedWebView.load(
                            view: view,
                            url: url.absoluteString,
                            referer: EmbeddedMediaPolicy.webReferer(for: url)
                        )
                        return view
                    },
                    update: { view in
                        if view.url != url.absoluteString {
                            AndroidEmbeddedWebView.load(
                                view: view,
                                url: url.absoluteString,
                                referer: EmbeddedMediaPolicy.webReferer(for: url)
                            )
                        }
                    }
                )
            }
            .frame(height: 240)
            #else
            Link(url.absoluteString, destination: url)
            #endif
        } else {
            Text("Invalid embed URL")
                .foregroundStyle(.secondary)
        }
    }
}

#if !SKIP && os(iOS)
private struct AppleWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        return WKWebView(frame: .zero, configuration: configuration)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        var request = URLRequest(url: url)
        for (field, value) in EmbeddedMediaPolicy.webRequestHeaders(for: url) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        webView.load(request)
    }

    final class Coordinator {
        var loadedURL: URL?
    }
}
#endif
