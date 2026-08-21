import Foundation
import Testing
@testable import LogseqChatModel

#if !SKIP
@Suite(.serialized) struct PendingAssetSyncTests {
    @Test @MainActor func authenticatedConfigurationStartsPendingSyncAfterConfigureApplies() async throws {
        let recorder = PendingSyncRequestRecorder()
        let store = LogseqChatStore { request in
            recorder.append(request)
            return #"{"apiVersion":1,"ok":true,"result":{"revision":1,"blocks":[],"selectedBlock":null},"error":null}"#
        }

        await store.configureAndSelectGraph(
            baseURL: "https://api-staging.logseq.io",
            token: "access-token",
            selectedGraphID: "graph-1"
        )

        try await waitUntil {
            recorder.all.contains { $0.contains("\"action\":\"beginPendingSync\"") }
        }
        let requests = recorder.all
        let configureIndex = try #require(
            requests.firstIndex { $0.contains("\"action\":\"configure\"") }
        )
        let pendingIndex = try #require(
            requests.firstIndex { $0.contains("\"action\":\"beginPendingSync\"") }
        )
        #expect(configureIndex < pendingIndex)
    }

    @Test func pendingAssetUploadResolvesStoredPathAgainstDocumentsDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("logseq-chat-pending-asset-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assetURL = root.appendingPathComponent("Assets/photo.jpg")
        try FileManager.default.createDirectory(
            at: assetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("asset".utf8).write(to: assetURL)

        let resolved = LogseqPendingSyncFilePath.resolve(
            "Assets/photo.jpg",
            documentsDirectory: root
        )

        #expect(resolved == assetURL.standardizedFileURL)
    }

    @Test func pendingAssetUploadRejectsMissingStoredPath() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("logseq-chat-missing-asset-\(UUID().uuidString)", isDirectory: true)

        #expect(
            LogseqPendingSyncFilePath.resolve(
                "Assets/missing.jpg",
                documentsDirectory: root
            ) == nil
        )
    }
}

private final class PendingSyncRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}

@MainActor private func waitUntil(
    timeout: TimeInterval = 1.0,
    condition: @escaping @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
}
#endif
