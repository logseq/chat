import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct InlineImageHost: View {
    let url: URL

    var body: some View {
        LGChatInlineImage(url: url)
            .frame(width: 326, alignment: .leading)
            .background(Color.white)
    }
}

private func writeFixtureImage(to url: URL) {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 300), format: format)
        .image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 300))
        }
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ), let cgImage = image.cgImage else {
        fatalError("Could not create fixture image")
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("Could not write fixture image")
    }
}

@MainActor
private func renderedDarkBounds(
    url: URL,
    settleInterval: TimeInterval,
    height: CGFloat = 340
) -> CGRect? {
    let host = UIHostingController(rootView: InlineImageHost(url: url))
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 326, height: height))
    window.rootViewController = host
    window.makeKeyAndVisible()
    RunLoop.main.run(until: Date().addingTimeInterval(settleInterval))
    host.view.layoutIfNeeded()

    let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds)
    let snapshot = renderer.image { _ in
        host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
    }
    guard let cgImage = snapshot.cgImage,
          let data = cgImage.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data) else { return nil }

    let width = cgImage.width
    let height = cgImage.height
    let bytesPerRow = cgImage.bytesPerRow
    var minX = width
    var minY = height
    var maxX = -1
    var maxY = -1

    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * 4
            let blue = bytes[offset]
            let green = bytes[offset + 1]
            let red = bytes[offset + 2]
            if red < 24 && green < 24 && blue < 24 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
    }

    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

@main
struct InlineImageLayoutCheck {
    @MainActor static func main() {
        let fixture = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("logseq-inline-image-layout.png")
        writeFixtureImage(to: fixture)

        var failures = 0
        if let first = renderedDarkBounds(url: fixture, settleInterval: 0.8) {
            if first.minX > 4 {
                print("FAIL: inline image is centered instead of leading; minX=\(first.minX)")
                failures += 1
            }
        } else {
            print("FAIL: inline image did not render after initial load")
            failures += 1
        }

        if let second = renderedDarkBounds(url: fixture, settleInterval: 0.05) {
            if second.minX > 4 {
                print("FAIL: cached inline image is centered instead of leading; minX=\(second.minX)")
                failures += 1
            }
        } else {
            print("FAIL: cached inline image did not render immediately")
            failures += 1
        }

        guard failures == 0 else { exit(1) }
        print("PASS: inline image previews render leading-aligned and reuse cached thumbnails")
    }
}
