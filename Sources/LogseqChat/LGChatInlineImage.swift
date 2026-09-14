import ImageIO
import SwiftUI

#if os(iOS)
private final class LGChatInlineImageThumbnailBox {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

private final class LGChatInlineImageThumbnailCache: @unchecked Sendable {
    static let shared = LGChatInlineImageThumbnailCache()

    private let cache = NSCache<NSURL, LGChatInlineImageThumbnailBox>()

    private init() {
        cache.countLimit = 80
    }

    func image(for url: URL) -> CGImage? {
        cache.object(forKey: url as NSURL)?.image
    }

    func store(_ image: CGImage, for url: URL) {
        cache.setObject(LGChatInlineImageThumbnailBox(image), forKey: url as NSURL)
    }
}

struct LGChatInlineImage: View {
    private static let maximumPreviewSize = CGSize(width: 326, height: 280)

    let url: URL
    @State private var thumbnail: CGImage?

    init(url: URL) {
        self.url = url
        _thumbnail = State(
            initialValue: LGChatInlineImageThumbnailCache.shared.image(for: url)
        )
    }

    var body: some View {
        Group {
            if let thumbnail {
                let displaySize = Self.displaySize(for: thumbnail)
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .frame(width: displaySize.width, height: displaySize.height)
                    .clipShape(.rect(cornerRadius: 8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ProgressView().frame(height: 120)
            }
        }
        .accessibilityIdentifier("asset.preview.image")
        .task(id: url) {
            if let cached = LGChatInlineImageThumbnailCache.shared.image(for: url) {
                thumbnail = cached
                return
            }
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
            if let image {
                LGChatInlineImageThumbnailCache.shared.store(image, for: imageURL)
            }
            thumbnail = image
        }
    }

    private static func displaySize(for image: CGImage) -> CGSize {
        let width = max(CGFloat(image.width), 1)
        let height = max(CGFloat(image.height), 1)
        let scale = min(
            maximumPreviewSize.width / width,
            maximumPreviewSize.height / height,
            1
        )
        return CGSize(width: ceil(width * scale), height: ceil(height * scale))
    }
}
#endif
