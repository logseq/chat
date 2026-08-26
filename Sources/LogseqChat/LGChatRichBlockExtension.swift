import Foundation
import LogseqChatModel
import LUIAppleBackend
import Observation
import SwiftUI

@MainActor
enum LGChatExtensionRegistry {
    static func makeRegistry() throws -> LUIAppleExtensionRegistry {
        let registry = LUIAppleExtensionRegistry()
        try LGChatOutlinerEditorExtension.register(in: registry)
        try LGChatRichBlockExtension.register(
            in: registry,
            playback: LGChatYouTubePlaybackState()
        )
        return registry
    }
}

@MainActor
@Observable
private final class LGChatYouTubePlaybackState {
    var starts: [String: Int] = [:]
}

@MainActor
private enum LGChatRichBlockExtension {
    static let identifier = "outliner-block-content"
    static let fingerprint = "lui-extension-v1|22:outliner-block-content|profiles:android/swiftui,ios/swiftui,macos/swiftui|standard-children:0|children:|properties:11:markup-json:string:required:none,18:youtube-target-url:string:required:none,5:title:string:required:none|events:9:open-node[4:uuid:string:required]"

    static func register(
        in registry: LUIAppleExtensionRegistry,
        playback: LGChatYouTubePlaybackState
    ) throws {
        try registry.register(
            LUIAppleExtension(
                identifier: identifier,
                fingerprint: fingerprint,
                properties: [
                    .init(name: "title", kind: .string, isRequired: true),
                    .init(name: "markup-json", kind: .string, isRequired: true),
                    .init(name: "youtube-target-url", kind: .string, isRequired: true),
                ],
                events: [
                    .init(name: "open-node", fields: [
                        .init(name: "uuid", kind: .string, isRequired: true),
                    ]),
                ]
            ) { context in
                AnyView(LGChatRichBlock(context: context, playback: playback))
            }
        )
    }
}

@MainActor
private struct LGChatRichBlock: View {
    let context: LUIAppleExtensionViewContext
    let playback: LGChatYouTubePlaybackState

    var body: some View {
        OutlinerMixedRichMarkupContent(
            nodes: markupNodes,
            fallback: stringProperty("title"),
            precedingYouTubeURL: youtubeTargetURL,
            youtubePlaybackStarts: playback.starts,
            onSeekYouTube: { url, seconds in
                playback.starts[url] = seconds
            },
            onOpenMarkupLink: { link in
                switch link {
                case .node(let uuid):
                    emitOpenNode(uuid)
                }
            }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var markupNodes: [LogseqMarkupNode] {
        let data = Data(stringProperty("markup-json").utf8)
        return (try? JSONDecoder().decode([LogseqMarkupNode].self, from: data)) ?? []
    }

    private var youtubeTargetURL: String? {
        let value = stringProperty("youtube-target-url")
        return value.isEmpty ? nil : value
    }

    private func stringProperty(_ name: String) -> String {
        guard case let .string(value) = context.property(name) else { return "" }
        return value
    }

    private func emitOpenNode(_ uuid: String) {
        do {
            try context.emit(name: "open-node", values: ["uuid": .string(uuid)])
        } catch {
            logger.error("Could not emit rich block event: \(String(describing: error))")
        }
    }
}
