import Foundation

#if !SKIP
import CryptoKit
#endif

public struct SharedCapturePayload: Sendable, Equatable {
    public let text: String?
    public let title: String?
    public let url: String?

    public init(text: String?, title: String?, url: String?) {
        self.text = Self.nonEmpty(text)
        self.title = Self.nonEmpty(title)
        self.url = Self.nonEmpty(url)
    }

    public init(sharedText: String?, title: String?) {
        let sharedText = Self.nonEmpty(sharedText)
        let title = Self.nonEmpty(title)
        if let sharedText, Self.isWebURL(sharedText) {
            self.text = nil
            self.title = title
            self.url = sharedText
        } else if let sharedText, let title, sharedText.contains(title) {
            self.text = sharedText
            self.title = nil
            self.url = nil
        } else {
            self.text = sharedText
            self.title = title
            self.url = nil
        }
    }

    public init?(captureURL: URL) {
        guard captureURL.scheme?.lowercased() == "logseqchat",
              captureURL.host?.lowercased() == "capture",
              let components = URLComponents(url: captureURL, resolvingAgainstBaseURL: false)
        else { return nil }

        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = Self.nonEmpty(item.value) {
                values[item.name] = value
            }
        }
        self.text = Self.nonEmpty(values["text"])
        self.title = Self.nonEmpty(values["title"])
        self.url = Self.nonEmpty(values["url"])
        guard blockText != nil else { return nil }
    }

    public var blockText: String? {
        let link: String?
        if let url {
            link = title.map { $0 == url ? url : "[\($0)](\(url))" } ?? url
        } else {
            link = title
        }
        return [text, link]
            .compactMap { $0 }
            .joined(separator: "\n")
            .nilIfEmpty
    }

    private static func nonEmpty(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func isWebURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return false }
        return components.host?.nilIfEmpty != nil
    }
}

public enum LogseqDeepLink: Sendable, Equatable {
    case captureText(String)
    case openCapture
    case openJournal

    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == "logseqchat" else { return nil }
        let payload = SharedCapturePayload(captureURL: url)
        if payload != nil, payload!.blockText != nil {
            self = .captureText(payload!.blockText!)
        } else {
            switch url.host?.lowercased() {
            case "capture": self = .openCapture
            case "journal": self = .openJournal
            default: return nil
            }
        }
    }
}

public struct SharedCaptureAsset: Codable, Sendable, Equatable {
    public let title: String
    public let assetType: String
    public let size: Int
    public let checksum: String
    public let stagedFileName: String

    public init(
        title: String,
        assetType: String,
        size: Int,
        checksum: String,
        stagedFileName: String
    ) {
        self.title = title
        self.assetType = assetType
        self.size = size
        self.checksum = checksum
        self.stagedFileName = stagedFileName
    }
}

public struct SharedCaptureItem: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case text
        case asset
    }

    public let id: String
    public let kind: Kind
    public let captureText: String?
    public let captureAsset: SharedCaptureAsset?

    public static func text(id: String, text: String) -> SharedCaptureItem {
        SharedCaptureItem(id: id, kind: .text, captureText: text, captureAsset: nil)
    }

    public static func asset(id: String, asset: SharedCaptureAsset) -> SharedCaptureItem {
        SharedCaptureItem(id: id, kind: .asset, captureText: nil, captureAsset: asset)
    }
}

@MainActor public final class SharedCaptureInbox {
    #if !SKIP
    public static let shared = SharedCaptureInbox(directory: SharedCaptureStorage.queueDirectory)
    #else
    public static let shared = SharedCaptureInbox()
    #endif

    private let defaults: UserDefaults
    private let storageKey = "logseq.pendingSharedCaptureItems"
    #if !SKIP
    private let directory: URL?
    #endif

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if !SKIP
        self.directory = nil
        #endif
    }

    #if !SKIP
    public init(directory: URL) {
        self.defaults = .standard
        self.directory = directory
    }
    #endif

    public func enqueue(_ item: SharedCaptureItem) {
        guard !pendingItems().contains(where: { $0.id == item.id }) else { return }
        #if !SKIP
        if let directory {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            guard let data = try? JSONEncoder().encode(item) else { return }
            try? data.write(to: itemURL(id: item.id, in: directory), options: .atomic)
            return
        }
        #endif
        var pending = pendingItems()
        pending.append(item)
        save(pending)
    }

    public func enqueueText(_ text: String, id: String = UUID().uuidString.lowercased()) {
        guard let text = text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return
        }
        enqueue(.text(id: id, text: text))
    }

    public func enqueue(payload: SharedCapturePayload, id: String = UUID().uuidString.lowercased()) {
        guard let text = payload.blockText else { return }
        enqueue(.text(id: id, text: text))
    }

    public func pendingItems() -> [SharedCaptureItem] {
        #if !SKIP
        if let directory {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return urls
                .filter { $0.pathExtension == "json" }
                .sorted { lhs, rhs in
                    let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    if lhsDate == rhsDate { return lhs.lastPathComponent < rhs.lastPathComponent }
                    return lhsDate < rhsDate
                }
                .compactMap { url in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return try? JSONDecoder().decode(SharedCaptureItem.self, from: data)
                }
        }
        #endif
        guard let value = defaults.string(forKey: storageKey),
              let data = value.data(using: .utf8),
              let pending = try? JSONDecoder().decode([SharedCaptureItem].self, from: data)
        else { return [] }
        return pending
    }

    public func acknowledge(id: String) {
        #if !SKIP
        if let directory {
            try? FileManager.default.removeItem(at: itemURL(id: id, in: directory))
            return
        }
        #endif
        let remaining = pendingItems().filter { $0.id != id }
        if remaining.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else {
            save(remaining)
        }
    }

    private func save(_ pending: [SharedCaptureItem]) {
        guard let data = try? JSONEncoder().encode(pending),
              let value = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(value, forKey: storageKey)
    }

    #if !SKIP
    private func itemURL(id: String, in directory: URL) -> URL {
        let name = SHA256.hash(data: Data(id.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent("\(name).json", isDirectory: false)
    }
    #endif
}

@MainActor public enum SharedCaptureProcessor {
    public static func process(
        inbox: SharedCaptureInbox,
        handle: @MainActor (SharedCaptureItem) async -> Bool
    ) async {
        while let item = inbox.pendingItems().first {
            guard await handle(item) else { return }
            inbox.acknowledge(id: item.id)
        }
    }
}

@MainActor public enum ShortcutCapture {
    @discardableResult public static func enqueue(
        _ text: String,
        inbox: SharedCaptureInbox = .shared,
        id: String = UUID().uuidString.lowercased()
    ) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        inbox.enqueueText(text, id: id)
        return true
    }
}

#if !SKIP
public enum SharedCaptureStorage {
    public static let appGroupIdentifier = "group.com.logseq.chat"

    public static var sharedDirectory: URL {
        let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SharedCapture", isDirectory: true)
    }

    public static var queueDirectory: URL {
        let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SharedCaptureQueue", isDirectory: true)
    }
}

public struct ImportedSharedCaptureAsset: Sendable, Equatable {
    public let title: String
    public let assetType: String
    public let size: Int
    public let checksum: String
    public let localPath: String
}

public enum SharedCaptureAssetError: Error, Equatable {
    case missingStagedFile
    case invalidSize
    case invalidChecksum
}

public enum SharedCaptureAssetStager {
    public static func stage(
        sourceURL: URL,
        contentType: String,
        sharedDirectory: URL
    ) throws -> SharedCaptureAsset {
        let manager = FileManager.default
        try manager.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        let title = sourceURL.lastPathComponent
        let safeTitle = title.replacingOccurrences(of: "/", with: "-")
        let safeName = "\(UUID().uuidString.lowercased())-\(safeTitle)"
        let destination = sharedDirectory.appendingPathComponent(safeName, isDirectory: false)
        try manager.copyItem(at: sourceURL, to: destination)
        let data = try Data(contentsOf: destination)
        return SharedCaptureAsset(
            title: title,
            assetType: contentType,
            size: data.count,
            checksum: sha256(data),
            stagedFileName: safeName
        )
    }

    fileprivate static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum SharedCaptureAssetImporter {
    public static func importAsset(
        _ asset: SharedCaptureAsset,
        sharedDirectory: URL,
        documentsDirectory: URL
    ) throws -> ImportedSharedCaptureAsset {
        let manager = FileManager.default
        let assetsDirectory = documentsDirectory.appendingPathComponent("Assets", isDirectory: true)
        try manager.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        let destinationName = asset.stagedFileName
        let destination = assetsDirectory.appendingPathComponent(destinationName, isDirectory: false)
        let source = sharedDirectory.appendingPathComponent(asset.stagedFileName, isDirectory: false)

        if manager.fileExists(atPath: destination.path) {
            try validate(destination, against: asset)
            if manager.fileExists(atPath: source.path) {
                try manager.removeItem(at: source)
            }
        } else {
            guard manager.fileExists(atPath: source.path) else {
                throw SharedCaptureAssetError.missingStagedFile
            }
            try validate(source, against: asset)
            try manager.copyItem(at: source, to: destination)
            try manager.removeItem(at: source)
        }
        return ImportedSharedCaptureAsset(
            title: asset.title,
            assetType: asset.assetType,
            size: asset.size,
            checksum: asset.checksum,
            localPath: "Assets/\(destinationName)"
        )
    }

    private static func validate(_ file: URL, against asset: SharedCaptureAsset) throws {
        let data = try Data(contentsOf: file)
        guard data.count == asset.size else { throw SharedCaptureAssetError.invalidSize }
        guard SharedCaptureAssetStager.sha256(data) == asset.checksum else {
            throw SharedCaptureAssetError.invalidChecksum
        }
    }
}
#endif

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
