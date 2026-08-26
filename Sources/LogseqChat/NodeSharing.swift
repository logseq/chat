import Foundation
import LogseqChatModel

enum NodeSharePolicy {
    static func text(pageTitle: String, blocks: [LogseqBlock]) -> String {
        let lines = blocks
            .map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "- \($0)" }
        return ([pageTitle] + lines).joined(separator: "\n")
    }

    static func localAssetPaths(blocks: [LogseqBlock]) -> [String] {
        var paths: [String] = []
        var seen = Set<String>()
        for block in blocks where block.isAsset {
            guard let path = block.localPath, !path.isEmpty, !seen.contains(path) else {
                continue
            }
            seen.insert(path)
            paths.append(path)
        }
        return paths
    }
}

#if !SKIP && os(iOS)
import SwiftUI
import UIKit

struct NodeSharePayload: Identifiable {
    let id = UUID()
    let items: [Any]

    init(pageTitle: String, blocks: [LogseqBlock]) {
        var items: [Any] = [NodeSharePolicy.text(pageTitle: pageTitle, blocks: blocks)]
        var sharedURLs = Set<URL>()
        for block in blocks where block.isAsset {
            guard
                let url = LocalAssetPath.resolve(
                    block.localPath,
                    title: block.title,
                    assetType: block.assetType
                ),
                !sharedURLs.contains(url)
            else {
                continue
            }
            sharedURLs.insert(url)
            items.append(url)
        }
        self.items = items
    }

    init(text: String, localAssetPaths: [String]) {
        var items: [Any] = [text]
        var sharedURLs = Set<URL>()
        for path in localAssetPaths {
            let title = URL(fileURLWithPath: path).lastPathComponent
            guard
                let url = LocalAssetPath.resolve(path, title: title, assetType: nil),
                !sharedURLs.contains(url)
            else {
                continue
            }
            sharedURLs.insert(url)
            items.append(url)
        }
        self.items = items
    }
}

struct NodeShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
