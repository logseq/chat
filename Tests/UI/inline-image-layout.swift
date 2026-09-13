import SwiftUI
import UIKit

@main struct InlineImageCheck {
    static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(ImageCheckDelegate.self))
    }
}

@MainActor final class ImageCheckDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent("portrait.png")
        let source = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 200)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 200))
        }
        try! source.pngData()!.write(to: url)
        let host = UIHostingController(rootView: LGChatInlineImage(url: url)
            .frame(width: 360, height: 280, alignment: .topLeading).background(.white))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 280))
        window.rootViewController = host
        self.window = window
        window.makeKeyAndVisible()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            host.view.frame = CGRect(x: 0, y: 0, width: 360, height: 280)
            host.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let rendered = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 280), format: format).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            try! rendered.pngData()!.write(to: directory.appendingPathComponent("image.png"))
            let image = rendered.cgImage!
            var bytes = [UInt8](repeating: 0, count: 360 * 280 * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: 360, height: 280,
                                        bitsPerComponent: 8, bytesPerRow: 360 * 4,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: 360, height: 280))
            }
            func white(_ x: Int, _ y: Int) -> Bool { bytes[(y * 360 + x) * 4 + 1] > 230 }
            let corners = [(0, 0), (139, 0), (0, 279), (139, 279)]
            let passed = corners.allSatisfy { white($0.0, $0.1) }
                && !white(70, 140) && white(150, 140)
            try! (passed ? "PASS: all four image corners are rounded at the image bounds" : "FAIL: image corners or size are incorrect")
                .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        }
        return true
    }
}
