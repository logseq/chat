import Foundation
import LogseqChatModel
import LUIAppleBackend
import Observation
import SwiftUI
#if !SKIP && os(iOS)
import UIKit
import UniformTypeIdentifiers
#endif

@MainActor
enum LGChatExtensionRegistry {
    static func makeRegistry() throws -> LUIAppleExtensionRegistry {
        let registry = LUIAppleExtensionRegistry()
        try LGChatNavigationExtension.register(in: registry)
        try LGChatSearchPresentationExtension.register(in: registry)
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

#if !SKIP && os(iOS)
private struct OutlinerRowHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 44

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct OutlinerRowDropDelegate: DropDelegate {
    let rowHeight: CGFloat
    let onDrop: (OutlinerDropPlacement) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText])
    }

    func performDrop(info: DropInfo) -> Bool {
        onDrop(OutlinerDropZone.placement(
            locationY: info.location.y,
            rowHeight: rowHeight
        ))
    }
}
#endif

@MainActor
private enum LGChatRichBlockExtension {
    static let identifier = "outliner-block-content"
    static let fingerprint = "lui-extension-v1|22:outliner-block-content|profiles:android/swiftui,ios/swiftui,macos/swiftui|standard-children:0|children:|properties:10:asset-type:string:required:none,10:local-path:string:required:none,11:markup-json:string:required:none,12:is-completed:bool:required:none,18:youtube-target-url:string:required:none,5:title:string:required:none,8:block-id:string:required:none,8:is-asset:bool:required:none|events:10:drag-start[4:uuid:string:required],4:drop[4:uuid:string:required,9:placement:string:required],9:open-node[4:uuid:string:required]"

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
                    .init(name: "block-id", kind: .string, isRequired: true),
                    .init(name: "markup-json", kind: .string, isRequired: true),
                    .init(name: "youtube-target-url", kind: .string, isRequired: true),
                    .init(name: "is-asset", kind: .bool, isRequired: true),
                    .init(name: "is-completed", kind: .bool, isRequired: true),
                    .init(name: "asset-type", kind: .string, isRequired: true),
                    .init(name: "local-path", kind: .string, isRequired: true),
                ],
                events: [
                    .init(name: "drag-start", fields: [
                        .init(name: "uuid", kind: .string, isRequired: true),
                    ]),
                    .init(name: "drop", fields: [
                        .init(name: "uuid", kind: .string, isRequired: true),
                        .init(name: "placement", kind: .string, isRequired: true),
                    ]),
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
    @State private var measuredHeight: CGFloat = 44

    var body: some View {
        #if !SKIP && os(iOS)
        content
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: OutlinerRowHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            }
            .onPreferenceChange(OutlinerRowHeightPreferenceKey.self) { measuredHeight = $0 }
            .onDrag {
                emitDragStart()
                return NSItemProvider(object: blockID as NSString)
            }
            .onDrop(
                of: [UTType.plainText],
                delegate: OutlinerRowDropDelegate(
                    rowHeight: measuredHeight,
                    onDrop: emitDrop
                )
            )
        #else
        content
        #endif
    }

    private var content: some View {
        Group {
            if boolProperty("is-asset") {
                LGChatAssetPreview(
                    title: stringProperty("title"),
                    assetType: stringProperty("asset-type"),
                    localPath: stringProperty("local-path")
                )
            } else {
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .strikethrough(boolProperty("is-completed"))
        .foregroundStyle(boolProperty("is-completed") ? .secondary : .primary)
    }

    private var blockID: String {
        stringProperty("block-id")
    }

    private func boolProperty(_ name: String) -> Bool {
        guard case let .bool(value) = context.property(name) else { return false }
        return value
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

    private func emitDragStart() {
        do {
            try context.emit(name: "drag-start", values: ["uuid": .string(blockID)])
        } catch {
            logger.error("Could not emit block drag event: \(String(describing: error))")
        }
    }

    private func emitDrop(_ placement: OutlinerDropPlacement) -> Bool {
        do {
            try context.emit(name: "drop", values: [
                "uuid": .string(blockID),
                "placement": .string(placement.eventValue),
            ])
            return true
        } catch {
            logger.error("Could not emit block drop event: \(String(describing: error))")
            return false
        }
    }
}

@MainActor
enum LGChatAssetPreviewPolicy {
    static func usesInlineAudioPlayer(assetType: String, localPath: String) -> Bool {
        !localPath.isEmpty
            && AssetPresentationPolicy.kind(
                assetType: assetType,
                localPath: localPath
            ) == .audio
    }
}

@MainActor
private struct LGChatAssetPreview: View {
    let title: String
    let assetType: String
    let localPath: String

    var body: some View {
        #if !SKIP && os(iOS)
        if kind == .image,
           let url = LocalAssetPath.resolve(
               localPath,
               title: title,
               assetType: assetType
           ),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityIdentifier("asset.preview.image")
        } else if LGChatAssetPreviewPolicy.usesInlineAudioPlayer(
            assetType: assetType,
            localPath: localPath
        ), let url = LocalAssetPath.resolve(
            localPath,
            title: title,
            assetType: assetType
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: title.isEmpty ? "Untitled file" : title)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(3)
                AssetAudioPlayer(path: url.path)
                    .frame(height: 44)
            }
        } else {
            fileSummary
        }
        #else
        fileSummary
        #endif
    }

    private var kind: AssetPresentationKind {
        AssetPresentationPolicy.kind(assetType: assetType, localPath: localPath)
    }

    private var fileSummary: some View {
        HStack(spacing: 8) {
            IconImage(name: kind == .audio ? "audio" : "paperclip")
                .frame(width: 18, height: 18)
            Text(verbatim: title.isEmpty ? "Untitled file" : title)
                .font(.body)
                .fontWeight(.medium)
                .lineLimit(3)
        }
        .accessibilityIdentifier("asset.preview.file")
    }
}
