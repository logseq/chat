import ImageIO
import LogseqChatModel
import LUIAppleBackend
import SwiftUI

@MainActor
enum LGChatComposerAssetExtension {
    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.register(LUIAppleExtension(
            identifier: "composer-asset",
            fingerprint: "lui-extension-v1|14:composer-asset|profiles:ios/swiftui,macos/swiftui|standard-children:0|children:|properties:10:local-path:string:required:none,5:title:string:required:none|events:",
            properties: [
                .init(name: "title", kind: .string, isRequired: true),
                .init(name: "local-path", kind: .string, isRequired: true),
            ],
            events: []
        ) { context in
            AnyView(LGChatComposerAssetPreview(context: context))
        })
    }
}

private struct LGChatComposerAssetPreview: View {
    let context: LUIAppleExtensionViewContext
    @State private var thumbnail: CGImage?

    private var title: String {
        guard case let .string(value) = context.property("title") else { return "" }
        return value
    }

    private var path: String {
        guard case let .string(value) = context.property("local-path") else { return "" }
        return value
    }

    var body: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable().scaledToFill()
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "doc")
                    Text(verbatim: title).font(.caption2).lineLimit(2)
                }
                .padding(4)
            }
        }
        .frame(width: 128, height: 128)
        .background(.quaternary)
        .clipShape(.rect(cornerRadius: 12))
        .accessibilityLabel(title)
        .task(id: path) {
            let localPath = path
            let name = title
            thumbnail = await Task.detached(priority: .utility) {
                guard let url = LocalAssetPath.resolve(localPath, title: name, assetType: ""),
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 384,
                ] as CFDictionary)
            }.value
        }
    }
}
