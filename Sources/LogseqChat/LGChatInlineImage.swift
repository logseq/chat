import ImageIO
import SwiftUI

#if os(iOS)
struct LGChatInlineImage: View {
    let url: URL
    @State private var thumbnail: CGImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 280)
                    .clipShape(.rect(cornerRadius: 8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ProgressView().frame(height: 120)
            }
        }
        .accessibilityIdentifier("asset.preview.image")
        .task(id: url) {
            let imageURL = url
            let image = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, [
                    kCGImageSourceShouldCache: false,
                ] as CFDictionary) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1200,
                ] as CFDictionary)
            }.value
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
    }
}
#endif
