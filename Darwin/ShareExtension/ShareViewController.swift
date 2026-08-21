import CryptoKit
import Foundation
import OSLog
import UIKit
import UniformTypeIdentifiers

private enum SharedCaptureConstants {
    static let appGroup = "group.com.logseq.chat"
    static let storageKey = "logseq.pendingSharedCaptureItems"
    static let logger = Logger(subsystem: "com.logseq.chat.share", category: "SharedCapture")
}

private struct SharedAsset: Codable, Sendable {
    let title: String
    let assetType: String
    let size: Int
    let checksum: String
    let stagedFileName: String
}

private struct SharedItem: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text
        case asset
    }

    let id: String
    let kind: Kind
    let captureText: String?
    let captureAsset: SharedAsset?

    static func text(_ text: String) -> SharedItem {
        SharedItem(
            id: UUID().uuidString.lowercased(),
            kind: .text,
            captureText: text,
            captureAsset: nil
        )
    }

    static func asset(_ asset: SharedAsset) -> SharedItem {
        SharedItem(
            id: UUID().uuidString.lowercased(),
            kind: .asset,
            captureText: nil,
            captureAsset: asset
        )
    }
}

private final class CaptureAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var text: String?
    private var url: String?
    private var assets: [SharedItem] = []

    func setText(_ value: String) {
        lock.withLock { text = value }
    }

    func setURL(_ value: String) {
        lock.withLock { url = value }
    }

    func append(_ asset: SharedItem) {
        lock.withLock { assets.append(asset) }
    }

    func snapshot() -> (text: String?, url: String?, assets: [SharedItem]) {
        lock.withLock { (text, url, assets) }
    }
}

@MainActor final class ShareViewController: UIViewController {
    private var didStart = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        view.backgroundColor = .systemBackground
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.accessibilityLabel = "Saving to Logseq"
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        captureInput()
    }

    private func captureInput() {
        let inputItems = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let title = inputItems.compactMap { $0.attributedTitle?.string.trimmed }.first
        let providers = inputItems.flatMap { $0.attachments ?? [] }
        SharedCaptureConstants.logger.notice("Capture started with \(providers.count) providers")
        let group = DispatchGroup()
        let accumulator = CaptureAccumulator()

        for provider in providers {
            if let assetType = assetType(for: provider) {
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: assetType.identifier) { fileURL, _ in
                    defer { group.leave() }
                    guard let fileURL, let asset = try? Self.stage(fileURL, type: assetType) else { return }
                    accumulator.append(.asset(asset))
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                    defer { group.leave() }
                    let value = (item as? URL)?.absoluteString ?? (item as? NSURL)?.absoluteString
                    if let value = value?.trimmed {
                        accumulator.setURL(value)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                    defer { group.leave() }
                    if let value = (item as? String)?.trimmed {
                        accumulator.setText(value)
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let snapshot = accumulator.snapshot()
            var captures: [SharedItem] = []
            if let blockText = Self.blockText(
                text: snapshot.text,
                title: title,
                url: snapshot.url
            ) {
                captures.append(.text(blockText))
            }
            captures.append(contentsOf: snapshot.assets)
            if !captures.isEmpty {
                Self.persist(captures)
            }
            SharedCaptureConstants.logger.notice("Capture completed with \(captures.count) items")
            self.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func assetType(for provider: NSItemProvider) -> UTType? {
        provider.registeredTypeIdentifiers
            .compactMap(UTType.init)
            .first { type in
                type.conforms(to: .image) || type.conforms(to: .audio) ||
                    type.conforms(to: .movie) || type.conforms(to: .pdf) ||
                    (type.conforms(to: .data) && !type.conforms(to: .plainText) &&
                        !type.conforms(to: .url))
            }
    }

    nonisolated private static func stage(_ source: URL, type: UTType) throws -> SharedAsset {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedCaptureConstants.appGroup
        ) else { throw CocoaError(.fileNoSuchFile) }
        let directory = container.appendingPathComponent("SharedCapture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let title = source.lastPathComponent.isEmpty ? "Attachment" : source.lastPathComponent
        let stagedName = "\(UUID().uuidString.lowercased())-\(title.replacingOccurrences(of: "/", with: "-"))"
        let destination = directory.appendingPathComponent(stagedName, isDirectory: false)
        try FileManager.default.copyItem(at: source, to: destination)
        let data = try Data(contentsOf: destination)
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return SharedAsset(
            title: title,
            assetType: type.preferredMIMEType ?? type.preferredFilenameExtension ?? type.identifier,
            size: data.count,
            checksum: checksum,
            stagedFileName: stagedName
        )
    }

    nonisolated private static func blockText(text: String?, title: String?, url: String?) -> String? {
        let link: String?
        if let url {
            link = title.map { $0 == url ? url : "[\($0)](\(url))" } ?? url
        } else if let title, text?.contains(title) != true {
            link = title
        } else {
            link = nil
        }
        return [text, link].compactMap { $0 }.joined(separator: "\n").trimmed
    }

    nonisolated private static func persist(_ additions: [SharedItem]) {
        guard let defaults = UserDefaults(suiteName: SharedCaptureConstants.appGroup) else {
            SharedCaptureConstants.logger.error("App group defaults are unavailable")
            return
        }
        var pending: [SharedItem] = []
        if let value = defaults.string(forKey: SharedCaptureConstants.storageKey),
           let data = value.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([SharedItem].self, from: data) {
            pending = decoded
        }
        pending.append(contentsOf: additions)
        guard let data = try? JSONEncoder().encode(pending),
              let value = String(data: data, encoding: .utf8) else {
            SharedCaptureConstants.logger.error("Failed to encode shared captures")
            return
        }
        defaults.set(value, forKey: SharedCaptureConstants.storageKey)
        SharedCaptureConstants.logger.notice("Persisted \(pending.count) shared captures")
    }
}

private extension String {
    var trimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
