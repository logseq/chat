import Testing
import Foundation
@testable import LogseqChatModel

private let testEmptySnapshotJSON = """
{
  "apiVersion": 1,
  "ok": true,
  "result": {
    "revision": 1,
    "query": "",
    "blocks": [],
    "selectedBlock": null,
    "lastRefreshAt": null,
    "graphName": null,
    "isSearching": false
  },
  "error": null
}
"""

@Suite(.serialized) struct LogseqChatModelTests {

    @Test func logseqChatModel() throws {
        #expect(1 + 2 == 3, "basic test")
    }

    @Test func decodeType() throws {
        // load the TestData.json file from the Resources folder and decode it into a struct
        let resourceURL: URL = try #require(Bundle.module.url(forResource: "TestData", withExtension: "json"))
        let testData = try JSONDecoder().decode(TestData.self, from: Data(contentsOf: resourceURL))
        #expect(testData.testModuleName == "LogseqChatModel")
    }

    @Test func failedSyncStatusIsSeparateFromPending() throws {
        let failedBlock = LogseqBlock(
            uuid: "failed",
            kind: "block",
            title: "Failed",
            pageId: "journal/2026-08-13",
            parentId: nil,
            createdAt: 1_776_000_000_000,
            updatedAt: 1_776_000_000_000,
            syncStatus: "failed"
        )
        let pendingBlock = LogseqBlock(
            uuid: "pending",
            kind: "block",
            title: "Pending",
            pageId: "journal/2026-08-13",
            parentId: nil,
            createdAt: 1_776_000_000_001,
            updatedAt: 1_776_000_000_001,
            syncStatus: "pending"
        )

        #expect(failedBlock.isFailedSync)
        #expect(!failedBlock.isPendingSync)
        #expect(!pendingBlock.isFailedSync)
        #expect(pendingBlock.isPendingSync)
    }

    @Test func decodesTaskTagsReferencesAndAssetMetadata() throws {
        let data = Data(##"{"uuid":"asset-1","kind":"asset","title":"photo.jpg","pageId":"journal-1","createdAt":1,"updatedAt":2,"tags":[{"uuid":"tag-1","kind":"tag","title":"Project"}],"references":[{"uuid":"page-1","kind":"page","title":"Project"}],"status":{"uuid":"status-1","ident":"user.status/waiting","title":"Waiting","icon":{"type":"tabler-icon","id":"clock","color":"#7c3aed"}},"assetType":"jpg","assetSize":2048,"assetChecksum":"abc","localPath":"/documents/photo.jpg"}"##.utf8)
        let block = try JSONDecoder().decode(LogseqBlock.self, from: data)
        #expect(block.tags.first?.title == "Project")
        #expect(block.references.first?.kind == "page")
        #expect(block.status?.icon?.id == "clock")
        #expect(block.status?.icon?.color == "#7c3aed")
        #expect(block.assetType == "jpg")
        #expect(block.assetSize == 2048)
        #expect(block.localPath == "/documents/photo.jpg")
    }

    @Test func builtInTaskStatusesMatchLogseq() {
        #expect(LogseqTaskStatus.builtIn.map(\.title) == [
            "Backlog", "Todo", "Doing", "In Review", "Done", "Canceled"
        ])
        #expect(LogseqTaskStatus.builtIn.compactMap { $0.icon?.id } == [
            "Backlog", "Todo", "InProgress50", "InReview", "Done", "Cancelled"
        ])
    }

    @Test func snapshotDecodesCustomTaskStatusCatalog() throws {
        let data = Data(##"{"revision":1,"query":"","blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":"Test","isSearching":false,"taskStatuses":[{"uuid":"status-1","ident":"user.status/waiting","title":"Waiting","icon":{"type":"tabler-icon","id":"clock","color":"#7c3aed"}}]}"##.utf8)
        let snapshot = try JSONDecoder().decode(LogseqChatSnapshot.self, from: data)
        #expect(snapshot.taskStatuses?.first?.title == "Waiting")
        #expect(snapshot.taskStatuses?.first?.icon?.color == "#7c3aed")
    }

    @Test func snapshotPreservesGraphEncryptionAndReadiness() throws {
        let data = Data(#"{"revision":1,"query":"","blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":null,"selectedGraphId":null,"graphs":[{"id":"plain-1","name":"Plain","isEncrypted":false,"isReady":true},{"id":"encrypted-1","name":"Encrypted","isEncrypted":true,"isReady":true}],"isSearching":false}"#.utf8)
        let snapshot = try JSONDecoder().decode(LogseqChatSnapshot.self, from: data)
        #expect(snapshot.graphs?.map(\.id) == ["plain-1", "encrypted-1"])
        #expect(snapshot.graphs?.first?.isEncrypted == false)
        #expect(snapshot.graphs?.last?.isEncrypted == true)
        #expect(snapshot.graphs?.allSatisfy(\.isReady) == true)
    }

    @Test @MainActor func selectingGraphUsesExplicitGraphID() async throws {
        let recorder = RequestRecorder()
        let store = LogseqChatStore { request in
            recorder.append(request)
            return testEmptySnapshotJSON
        }
        store.selectGraph("plain-1")
        try await waitUntil {
            recorder.all.contains {
                $0.contains("\"action\":\"selectGraph\"")
                    && $0.contains("\"payload\":\"plain-1\"")
            }
        }
    }

    #if !SKIP
    @Test func snapshotMetadataRequestUsesSyncAPIAndOAuthBearerToken() throws {
        let request = try LogseqGraphSyncHTTP.snapshotMetadataRequest(
            baseURL: "http://127.0.0.1:8787/api",
            graphID: "plain graph",
            accessToken: "oauth-token"
        )
        #expect(request.url?.absoluteString == "http://127.0.0.1:8787/sync/plain%20graph/snapshot/download")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer oauth-token")
    }
    #endif

    #if !SKIP
    @Test func gzipSnapshotIsDecodedBeforeNativeImport() throws {
        let compressed = try #require(Data(base64Encoded: "H4sIAAAAAAAC/2NgYGB2dHIGAMqqG9MHAAAA"))
        let compressedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("logseq-snapshot-\(UUID().uuidString).gz")
        try compressed.write(to: compressedURL)
        defer { try? FileManager.default.removeItem(at: compressedURL) }

        let decodedURL = try LogseqGraphSyncHTTP.decodeSnapshotFile(
            at: compressedURL,
            contentEncoding: "gzip"
        )
        defer {
            if decodedURL != compressedURL {
                try? FileManager.default.removeItem(at: decodedURL)
            }
        }

        #expect(try Data(contentsOf: decodedURL) == Data([0, 0, 0, 3, 65, 66, 67]))
    }
    #endif

    #if !SKIP
    @Test func graphEventsRequestResumesFromAuthoritativeCursor() throws {
        let request = try LogseqGraphSyncHTTP.eventsRequest(
            baseURL: "http://127.0.0.1:8787",
            graphID: "plain-1",
            appliedServerT: 48192,
            accessToken: "fresh-token"
        )
        #expect(request.url?.absoluteString == "http://127.0.0.1:8787/sync/plain-1/events?since=48192")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    }
    #endif

    #if !SKIP
    @Test func sseTransportPreservesBlankLineFrameBoundary() throws {
        var buffer = LogseqGraphSSETransportBuffer()
        let first = try buffer.append(Data("id: 39\nevent: graph-changes\ndata: payload\n".utf8))
        let second = try buffer.append(Data("\n".utf8))

        #expect(first.isEmpty)
        #expect(second == ["id: 39\nevent: graph-changes\ndata: payload\n\n"])
    }
    #endif

    @Test @MainActor func graphDiscoveryRunsWhenThereIsNoCachedSelection() async throws {
        let recorder = RequestRecorder()
        let store = LogseqChatStore { request in
            recorder.append(request)
            let result: String
            if request.contains("\"action\":\"refresh\"") {
                result = #"{"revision":1,"query":"","blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":null,"selectedGraphId":null,"graphs":[{"id":"plain-1","name":"Sync 2","isEncrypted":false,"isReady":true}],"isSearching":false}"#
            } else if request.contains("\"action\":\"selectGraph\"") {
                result = #"{"revision":1,"query":"","blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":"Sync 2","selectedGraphId":"plain-1","graphs":[{"id":"plain-1","name":"Sync 2","isEncrypted":false,"isReady":true}],"isSearching":false}"#
            } else {
                result = #"{"revision":1,"query":"","blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":null,"selectedGraphId":null,"graphs":[],"isSearching":false}"#
            }
            return #"{"apiVersion":1,"ok":true,"result":\#(result),"error":null}"#
        }

        await store.configureAndSelectGraph(
            baseURL: "http://127.0.0.1:8787",
            token: "oauth-token",
            selectedGraphID: nil
        )

        #expect(recorder.all.count == 2)
        #expect(recorder.all[0].contains("\"action\":\"configure\""))
        #expect(recorder.all[0].contains("\\\"graphId\\\":\\\"\\\""))
        #expect(recorder.all[1].contains("\"action\":\"refresh\""))
        #expect(store.snapshot.graphs?.first?.name == "Sync 2")
    }

    @Test @MainActor func selectedGraphRefreshesThePersistedCatalogWhenOnline() async throws {
        let recorder = RequestRecorder()
        let store = LogseqChatStore { request in
            recorder.append(request)
            if request.contains("\"action\":\"configure\"") {
                return #"{"apiVersion":1,"ok":true,"result":{"revision":1,"query":"","blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":"Sync 2","selectedGraphId":"plain-1","graphs":[{"id":"plain-1","name":"Sync 2","isEncrypted":false,"isReady":true}],"isSearching":false},"error":null}"#
            }
            if request.contains("\"action\":\"refreshGraphCatalog\"") {
                return #"{"apiVersion":1,"ok":true,"result":{"revision":2,"query":"","blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":"Sync 2","selectedGraphId":"plain-1","graphs":[{"id":"plain-1","name":"Sync 2","isEncrypted":false,"isReady":true}],"isSearching":false},"error":null}"#
            }
            return #"{"apiVersion":1,"ok":false,"result":null,"error":{"code":"offline","message":"Network unavailable"}}"#
        }

        await store.configureAndSelectGraph(
            baseURL: "http://192.168.10.116:8787",
            token: "cached-token",
            selectedGraphID: "plain-1"
        )

        #expect(recorder.all.count == 2)
        #expect(recorder.all[0].contains("\\\"graphId\\\":\\\"plain-1\\\""))
        #expect(recorder.all[1].contains("\"action\":\"refreshGraphCatalog\""))
        #expect(store.snapshot.selectedGraphId == "plain-1")
        #expect(store.snapshot.graphName == "Sync 2")
        #expect(store.lastError == nil)
    }

    @Test @MainActor func cachedGraphRestoresWithoutNetworkWhenOffline() async throws {
        let recorder = RequestRecorder()
        let store = LogseqChatStore { request in
            recorder.append(request)
            return #"{"apiVersion":1,"ok":true,"result":{"revision":1,"query":"","blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":"Sync 2","selectedGraphId":"plain-1","graphs":[{"id":"plain-1","name":"Sync 2","isEncrypted":false,"isReady":true}],"isSearching":false},"error":null}"#
        }

        await store.configureAndSelectGraph(
            baseURL: "http://192.168.10.116:8787",
            token: "",
            selectedGraphID: "plain-1"
        )

        #expect(recorder.all.count == 1)
        #expect(recorder.all[0].contains("\"action\":\"configure\""))
        #expect(store.snapshot.graphName == "Sync 2")
    }

    @Test @MainActor func taskAndAssetCreationDispatchDurableCoreWrites() async throws {
        let recorder = RequestRecorder()
        let store = LogseqChatStore { request in
            recorder.append(request)
            return testEmptySnapshotJSON
        }
        store.sendTask("Follow up", status: LogseqTaskStatus.todo)
        store.addAsset(
            title: "photo.jpg",
            assetType: "jpg",
            assetSize: 2048,
            assetChecksum: "abc",
            localPath: "/documents/photo.jpg"
        )
        #expect(store.snapshot.blocks.isEmpty)
        try await waitUntil {
            recorder.all.contains { $0.contains("\"action\":\"sendTask\"") }
                && recorder.all.contains { $0.contains("\"action\":\"addAsset\"") }
        }
        let assetRequest = try #require(
            recorder.all.last { $0.contains("\"action\":\"addAsset\"") }
        )
        #expect(UUID(uuidString: try #require(extractSendUUID(from: assetRequest))) != nil)
    }

    @Test @MainActor func updateBlockTitleAppliesCoreSnapshot() async throws {
        let block = LogseqBlock(
            uuid: "block-1",
            kind: "block",
            title: "Draft title",
            pageId: "page-1",
            parentId: nil,
            createdAt: 1_776_000_000_000,
            updatedAt: 1_776_000_000_000,
            syncStatus: "synced"
        )
        let recorder = RequestRecorder()
        let store = LogseqChatStore { request in
            recorder.append(request)
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 2,
                "query": "",
                "blocks": [
                  {
                    "uuid": "block-1",
                    "kind": "block",
                    "title": "Published title",
                    "pageId": "page-1",
                    "createdAt": 1776000000000,
                    "updatedAt": 1776000100000
                  }
                ],
                "selectedBlock": null,
                "lastRefreshAt": 1776000100000,
                "isSearching": false
              },
              "error": null
            }
            """
        }

        store.update(block: block, title: "Published title")

        try await waitUntil {
            recorder.first?.contains("\"action\":\"updateBlock\"") == true
                && store.snapshot.blocks.first?.title == "Published title"
        }

        let capturedRequest = try #require(recorder.first)
        #expect(capturedRequest.contains("\"action\":\"updateBlock\""))
        #expect(capturedRequest.contains("\\\"uuid\\\":\\\"block-1\\\""))
        #expect(capturedRequest.contains("\\\"title\\\":\\\"Published title\\\""))
        #expect(store.snapshot.blocks.first?.title == "Published title")
        #expect(store.snapshot.blocks.first?.updatedAt == 1_776_000_100_000)
    }

    @Test @MainActor func taskStatusUpdatesOptimisticallyAndPersistsCustomChoice() async throws {
        let recorder = RequestRecorder()
        let waiting = LogseqTaskStatus(
            uuid: "custom-waiting",
            ident: "user.status/waiting",
            title: "Waiting",
            icon: LogseqIcon(type: "tabler-icon", id: "clock", color: "#7c3aed")
        )
        let store = LogseqChatStore { request in
            recorder.append(request)
            let status = request.contains("\"action\":\"updateBlockStatus\"")
                || request.contains("\"action\":\"beginPendingSync\"")
                ? ##"{"uuid":"custom-waiting","ident":"user.status/waiting","title":"Waiting","icon":{"type":"tabler-icon","id":"clock","color":"#7c3aed"}}"##
                : ##"{"uuid":"todo","ident":"logseq.property/status.todo","title":"Todo"}"##
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 2,
                "query": "",
                "blocks": [{
                  "uuid": "task-1",
                  "kind": "task",
                  "title": "Follow up",
                  "pageId": "journal-1",
                  "createdAt": 1776000000000,
                  "updatedAt": 1776000100000,
                  "status": \(status)
                }],
                "selectedBlock": null,
                "lastRefreshAt": 1776000100000,
                "isSearching": false
              },
              "error": null
            }
            """
        }
        store.open(path: "/tmp/status-test.sqlite")
        try await waitUntil {
            store.snapshot.blocks.first?.uuid == "task-1"
        }
        let block = try #require(store.snapshot.blocks.first)

        store.updateStatus(block: block, status: waiting)

        #expect(store.snapshot.blocks.first?.status?.uuid == "custom-waiting")
        try await waitUntil {
            recorder.all.contains { $0.contains("\"action\":\"updateBlockStatus\"") }
        }
        #expect(store.snapshot.blocks.first?.status?.uuid == "custom-waiting")
        let request = try #require(
            recorder.all.last { $0.contains("\"action\":\"updateBlockStatus\"") }
        )
        #expect(request.contains("\\\"uuid\\\":\\\"task-1\\\""))
        #expect(request.contains("\\\"uuid\\\":\\\"custom-waiting\\\""))
        #expect(request.contains("\\\"iconColor\\\":\\\"#7c3aed\\\""))
    }

    @Test @MainActor func configureDoesNotBlockTheMainActorWhenCoreIsSlow() async throws {
        let recorder = RequestRecorder()
        let store = LogseqChatStore { request in
            recorder.append(request)
            if request.contains("\"action\":\"configure\"") {
                Thread.sleep(forTimeInterval: 0.25)
            }
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 1,
                "query": "",
                "blocks": [],
                "selectedBlock": null,
                "lastRefreshAt": null,
                "graphName": "pat test",
                "isSearching": false
              },
              "error": null
            }
            """
        }

        let start = Date()
        store.configure(baseURL: "https://api-staging.logseq.io", token: "token")
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.1)
        try await waitUntil {
            recorder.first?.contains("\"action\":\"configure\"") == true
                && store.snapshot.graphName == "pat test"
        }
    }

    @Test @MainActor func configureNormalizesStagingBaseURLAndToken() async throws {
        let recorder = RequestRecorder()
        let store = LogseqChatStore { request in
            recorder.append(request)
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 1,
                "query": "",
                "blocks": [],
                "selectedBlock": null,
                "lastRefreshAt": null,
                "graphName": null,
                "isSearching": false
              },
              "error": null
            }
            """
        }

        store.configure(baseURL: " https://staging-api.logseq.io ", token: " token-value ")

        try await waitUntil {
            recorder.first?.contains("\"action\":\"configure\"") == true
        }

        let request = try #require(recorder.first)
        #expect(request.contains("api-staging.logseq.io"))
        #expect(!request.contains("staging-api.logseq.io"))
        #expect(request.contains("token-value"))
    }

    @Test @MainActor func configureRefreshesAfterConnectionApplies() async throws {
        let recorder = RequestRecorder()
        let store = LogseqChatStore { request in
            recorder.append(request)
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 1,
                "query": "",
                "blocks": [
                  {
                    "uuid": "remote-1",
                    "kind": "block",
                    "title": "Remote block",
                    "pageId": "page-1",
                    "createdAt": 1776000000000,
                    "updatedAt": 1776000000000,
                    "syncStatus": "synced"
                  }
                ],
                "selectedBlock": null,
                "lastRefreshAt": 1776000000000,
                "graphName": "pat test",
                "isSearching": false
              },
              "error": null
            }
            """
        }

        store.configure(baseURL: "https://api-staging.logseq.io", token: "token")

        try await waitUntil {
            let requests = recorder.all
            return requests.contains { $0.contains("\"action\":\"configure\"") }
                && requests.contains { $0.contains("\"action\":\"refresh\"") }
                && requests.contains { $0.contains("\"action\":\"beginPendingSync\"") }
        }

        #expect(store.snapshot.graphName == "pat test")
        #expect(store.snapshot.blocks.first?.title == "Remote block")
    }

    @Test @MainActor func updateBlockTitleDoesNotBlockTheMainActorWhenCoreIsSlow() async throws {
        let block = LogseqBlock(
            uuid: "block-1",
            kind: "block",
            title: "Draft title",
            pageId: "page-1",
            parentId: nil,
            createdAt: 1_776_000_000_000,
            updatedAt: 1_776_000_000_000,
            syncStatus: "synced"
        )
        let recorder = RequestRecorder()
        let store = LogseqChatStore { request in
            recorder.append(request)
            if request.contains("\"action\":\"updateBlock\"") {
                Thread.sleep(forTimeInterval: 0.25)
            }
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 2,
                "query": "",
                "blocks": [
                  {
                    "uuid": "block-1",
                    "kind": "block",
                    "title": "Published title",
                    "pageId": "page-1",
                    "createdAt": 1776000000000,
                    "updatedAt": 1776000100000
                  }
                ],
                "selectedBlock": null,
                "lastRefreshAt": 1776000100000,
                "isSearching": false
              },
              "error": null
            }
            """
        }

        let start = Date()
        store.update(block: block, title: "Published title")
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.1)
        try await waitUntil {
            recorder.first?.contains("\"action\":\"updateBlock\"") == true
                && store.snapshot.blocks.first?.title == "Published title"
        }
    }

    @Test @MainActor func sendPublishesCoreResultBeforeSyncing() async throws {
        let recorder = RequestRecorder()
        let request = LogseqPendingSyncRequest(
            id: 1,
            method: "POST",
            url: "https://api.example/capture",
            body: "{}",
            token: "access-token",
            filePath: nil,
            contentType: "application/json"
        )
        let store = LogseqChatStore(
            call: { call in
                recorder.append(call)
                if call.contains("\"action\":\"beginPendingSync\"") {
                    return pendingPumpSnapshot(query: "", syncStatus: "pending", request: request)
                }
                if call.contains("\"action\":\"completePendingSync\"") {
                    return pendingPumpSnapshot(query: "", syncStatus: "submitted", request: nil)
                }
                return pendingPumpSnapshot(query: "", syncStatus: "pending", request: nil)
            },
            pendingTransport: { _ in
                LogseqPendingSyncResult(status: 201, body: #"{"uuid":"local-1"}"#, error: nil)
            }
        )

        store.send("Offline capture")

        try await waitUntil {
            recorder.first?.contains("\"action\":\"send\"") == true
        }

        try await waitUntil {
            recorder.all.contains { $0.contains("\"action\":\"completePendingSync\"") }
                && store.snapshot.blocks.first?.isPendingSync == false
        }

        let requests = recorder.all
        #expect(requests.contains { $0.contains("\"action\":\"beginPendingSync\"") })
        #expect(requests.contains { $0.contains("\"action\":\"completePendingSync\"") })
        #expect(store.snapshot.blocks.first?.isPendingSync == false)
    }

    @Test @MainActor func sendDoesNotBlockTheMainActorWhenCoreIsSlow() async throws {
        let recorder = RequestRecorder()
        let store = LogseqChatStore { request in
            recorder.append(request)
            if request.contains("\"action\":\"send\"") {
                Thread.sleep(forTimeInterval: 0.25)
            }
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 1,
                "query": "",
                "blocks": [
                  {
                    "uuid": "local-1",
                    "kind": "block",
                    "title": "Slow local capture",
                    "pageId": "journal/2026-08-13",
                    "createdAt": 1776000000000,
                    "updatedAt": 1776000000000,
                    "syncStatus": "pending"
                  }
                ],
                "selectedBlock": null,
                "lastRefreshAt": 1776000000000,
                "isSearching": false
              },
              "error": null
            }
            """
        }

        let start = Date()
        store.send("Slow local capture")
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.1)
        #expect(store.snapshot.blocks.isEmpty)
        try await waitUntil {
            recorder.first?.contains("\"action\":\"send\"") == true
                && store.snapshot.blocks.first?.title == "Slow local capture"
        }
        #expect(store.snapshot.blocks.first?.isPendingSync == true)
    }

    @Test @MainActor func pendingHTTPDoesNotBlockUnrelatedLocalCoreActions() async throws {
        let recorder = RequestRecorder()
        let transport = SuspendedPendingTransport()
        let store = LogseqChatStore(
            call: { request in
                recorder.append(request)
                if request.contains("\"action\":\"beginPendingSync\"") {
                    return pendingPumpSnapshot(
                        query: "",
                        syncStatus: "pending",
                        request: LogseqPendingSyncRequest(
                            id: 1,
                            method: "POST",
                            url: "https://api.example/api/v1/graphs/graph-1/capture",
                            body: #"{"blocks":[{"uuid":"local-1","title":"Offline capture"}]}"#,
                            token: "access-token",
                            filePath: nil,
                            contentType: "application/json"
                        )
                    )
                }
                if request.contains("\"action\":\"completePendingSync\"") {
                    return pendingPumpSnapshot(query: "local", syncStatus: "submitted", request: nil)
                }
                if request.contains("\"action\":\"searchLocal\"") {
                    return pendingPumpSnapshot(query: "local", syncStatus: "pending", request: nil)
                }
                return pendingPumpSnapshot(query: "", syncStatus: "pending", request: nil)
            },
            pendingTransport: { request in
                await transport.send(request)
            }
        )

        store.send("Offline capture")
        try await waitUntilAsync { await transport.hasStarted }

        store.searchLocal("local")
        try await waitUntil { store.snapshot.query == "local" }
        #expect(await transport.isWaiting)

        await transport.resume()
        try await waitUntil {
            recorder.all.contains { $0.contains("\"action\":\"completePendingSync\"") }
                && store.snapshot.blocks.first?.syncStatus == "submitted"
        }
    }

    @Test @MainActor func cancelingBackgroundPendingSyncCancelsTheHTTPTransport() async throws {
        let recorder = RequestRecorder()
        let transport = SuspendedPendingTransport()
        let store = LogseqChatStore(
            call: { request in
                recorder.append(request)
                if request.contains("\"action\":\"beginPendingSync\"") {
                    return pendingPumpSnapshot(
                        query: "",
                        syncStatus: "pending",
                        request: LogseqPendingSyncRequest(
                            id: 1,
                            method: "POST",
                            url: "https://api.example/capture",
                            body: "{}",
                            token: "access-token",
                            filePath: nil,
                            contentType: "application/json"
                        )
                    )
                }
                return pendingPumpSnapshot(query: "", syncStatus: "pending", request: nil)
            },
            pendingTransport: { request in
                await transport.send(request)
            }
        )

        let background = Task { await store.syncPendingForBackground() }
        try await waitUntilAsync { await transport.hasStarted }

        background.cancel()
        await background.value

        #expect(await transport.wasCancelled)
        #expect(recorder.all.contains { $0.contains("\"action\":\"cancelPendingSync\"") })
        #expect(!recorder.all.contains { $0.contains("\"action\":\"completePendingSync\"") })
    }

    @Test @MainActor func sendPublishesOnlyAfterTheLocalWriteIsDurable() async throws {
        let recorder = RequestRecorder()
        let store = LogseqChatStore { request in
            recorder.append(request)
            if request.contains("\"action\":\"send\"") {
                Thread.sleep(forTimeInterval: 0.25)
            }
            let uuid = latestSendUUID(in: recorder) ?? "local-durable"
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 1,
                "query": "",
                "blocks": [
                  {
                    "uuid": "\(uuid)",
                    "kind": "block",
                    "title": "Durable capture",
                    "pageId": "journal/2026-08-13",
                    "createdAt": 1776000000000,
                    "updatedAt": 1776000000000,
                    "syncStatus": "pending"
                  }
                ],
                "selectedBlock": null,
                "lastRefreshAt": 1776000000000,
                "isSearching": false
              },
              "error": null
            }
            """
        }

        let start = Date()
        store.send("Durable capture")

        #expect(Date().timeIntervalSince(start) < 0.1)
        #expect(store.snapshot.blocks.isEmpty)
        try await waitUntil {
            store.snapshot.blocks.first?.title == "Durable capture"
                && store.snapshot.blocks.first?.isPendingSync == true
        }
    }

    @Test @MainActor func searchLocalDispatchesCacheOnlySearch() async throws {
        let recorder = RequestRecorder()
        let store = LogseqChatStore { request in
            recorder.append(request)
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 1,
                "query": "offline",
                "blocks": [],
                "selectedBlock": null,
                "lastRefreshAt": null,
                "graphName": null,
                "isSearching": true
              },
              "error": null
            }
            """
        }

        store.searchLocal("offline")

        try await waitUntil {
            recorder.first?.contains("\"action\":\"searchLocal\"") == true
                && store.snapshot.query == "offline"
        }

        let request = try #require(recorder.first)
        #expect(request.contains("\"action\":\"searchLocal\""))
        #expect(!request.contains("\"action\":\"search\""))
        #expect(store.snapshot.query == "offline")
        #expect(store.snapshot.isSearching == true)
    }

    @Test @MainActor func searchLocalDoesNotBlockTheMainActorWhenCoreIsSlow() async throws {
        let recorder = RequestRecorder()
        let store = LogseqChatStore { request in
            recorder.append(request)
            if request.contains("\"action\":\"searchLocal\"") {
                Thread.sleep(forTimeInterval: 0.25)
            }
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 1,
                "query": "slow",
                "blocks": [],
                "selectedBlock": null,
                "lastRefreshAt": null,
                "graphName": null,
                "isSearching": true
              },
              "error": null
            }
            """
        }

        let start = Date()
        store.searchLocal("slow")
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.05)
        try await waitUntil {
            recorder.first?.contains("\"action\":\"searchLocal\"") == true
                && store.snapshot.query == "slow"
        }
    }

    @Test @MainActor func backgroundSyncOnlySubmitsPendingWrites() async throws {
        let recorder = RequestRecorder()
        let pendingRequest = LogseqPendingSyncRequest(
            id: 1,
            method: "POST",
            url: "https://api.example/capture",
            body: "{}",
            token: "access-token",
            filePath: nil,
            contentType: "application/json"
        )
        let store = LogseqChatStore(
            call: { request in
                recorder.append(request)
                if request.contains("\"action\":\"beginPendingSync\"") {
                    return pendingPumpSnapshot(query: "", syncStatus: "pending", request: pendingRequest)
                }
                return pendingPumpSnapshot(query: "", syncStatus: "submitted", request: nil)
            },
            pendingTransport: { _ in
                try? await Task.sleep(nanoseconds: 150_000_000)
                return LogseqPendingSyncResult(status: 201, body: #"{"uuid":"local-1"}"#, error: nil)
            }
        )

        let start = Date()
        await store.syncPendingForBackground()
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed >= 0.15)
        #expect(!recorder.all.contains { $0.contains("\"action\":\"refresh\"") })
        #expect(recorder.all.contains { $0.contains("\"action\":\"beginPendingSync\"") })
        #expect(recorder.all.contains { $0.contains("\"action\":\"completePendingSync\"") })
        #expect(store.snapshot.blocks.first?.syncStatus == "submitted")
    }

    @Test @MainActor func backgroundConfigurationUsesTheCachedGraphCatalog() async {
        let recorder = RequestRecorder()
        let store = LogseqChatStore { request in
            recorder.append(request)
            return testEmptySnapshotJSON
        }

        await store.configureAndSelectGraph(
            baseURL: "http://127.0.0.1:8787",
            token: "access-token",
            selectedGraphID: "graph-1",
            refreshGraphCatalog: false
        )

        #expect(recorder.all.contains { $0.contains("\"action\":\"configure\"") })
        #expect(!recorder.all.contains { $0.contains("\"action\":\"refreshGraphCatalog\"") })
        #expect(!recorder.all.contains { $0.contains("\"action\":\"refresh\"") })
    }

    @Test @MainActor func concurrentRefreshCallsAreCoalesced() async throws {
        let recorder = RequestRecorder()
        let store = LogseqChatStore { request in
            recorder.append(request)
            if request.contains("\"action\":\"refresh\"") {
                Thread.sleep(forTimeInterval: 0.25)
            }
            return testEmptySnapshotJSON
        }

        store.refresh()
        store.refresh()

        try await waitUntil(timeout: 1.0) {
            recorder.all.contains { $0.contains("\"action\":\"refresh\"") }
                && store.isRefreshing == false
        }

        let refreshCount = recorder.all.filter { $0.contains("\"action\":\"refresh\"") }.count
        #expect(refreshCount == 1)
    }

    #if !SKIP
    @Test @MainActor func nativeCoreCallsAreSerializedAcrossAsyncAndImmediateActions() async throws {
        let probe = CoreCallConcurrencyProbe()
        let store = LogseqChatStore { request in
            probe.call(request, delayingAction: "configure")
        }

        store.configure(
            baseURL: "https://api-staging.logseq.io",
            token: "token",
            refreshAfterApply: false
        )
        try await waitUntil {
            probe.events.contains("start configure")
        }

        let start = Date()
        store.open(path: "/tmp/serialized-core.sqlite")
        store.searchLocal("queued")
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.1)
        try await waitUntil(timeout: 2.0) {
            probe.events.contains("finish searchLocal")
        }
        #expect(probe.maximumConcurrentCalls == 1)
        #expect(probe.events == [
            "start configure",
            "finish configure",
            "start open",
            "finish open",
            "start searchLocal",
            "finish searchLocal",
        ])
    }

    @Test @MainActor func nativeCoreSerializationContinuesAfterAnErrorResponse() async throws {
        let probe = CoreCallConcurrencyProbe(failingAction: "configure")
        let store = LogseqChatStore { request in
            probe.call(request, delayingAction: "configure")
        }

        store.configure(
            baseURL: "https://api-staging.logseq.io",
            token: "token",
            refreshAfterApply: false
        )
        try await waitUntil {
            probe.events.contains("start configure")
        }
        store.searchLocal("after error")

        try await waitUntil(timeout: 2.0) {
            probe.events.contains("finish searchLocal")
        }
        try await waitUntil(timeout: 2.0) {
            store.snapshot.query == "after error" && store.lastError == nil
        }
        #expect(probe.maximumConcurrentCalls == 1)
        #expect(probe.events == [
            "start configure",
            "finish configure",
            "start searchLocal",
            "finish searchLocal",
        ])
        #expect(store.snapshot.query == "after error")
        #expect(store.lastError == nil)
    }

    @Test @MainActor func nativeCoreCallsAreSerializedAcrossStoreInstances() async throws {
        let probe = CoreCallConcurrencyProbe()
        let firstStore = LogseqChatStore { request in
            probe.call(request, delayingAction: "configure")
        }
        let secondStore = LogseqChatStore { request in
            probe.call(request, delayingAction: "configure")
        }

        firstStore.configure(
            baseURL: "https://api-staging.logseq.io",
            token: "token",
            refreshAfterApply: false
        )
        try await waitUntil {
            probe.events.contains("start configure")
        }
        secondStore.searchLocal("queued across stores")

        try await waitUntil(timeout: 2.0) {
            probe.events.contains("finish searchLocal")
        }
        #expect(probe.maximumConcurrentCalls == 1)
        #expect(probe.events == [
            "start configure",
            "finish configure",
            "start searchLocal",
            "finish searchLocal",
        ])
    }
    #endif

    #if !SKIP
    @Test @MainActor func nativeCoreCallsStayOnOneOperatingSystemThreadAcrossStores() async throws {
        let probe = CoreCallConcurrencyProbe()
        let firstStore = LogseqChatStore { request in
            probe.call(request, delayingAction: "never")
        }
        let secondStore = LogseqChatStore { request in
            probe.call(request, delayingAction: "never")
        }

        for index in 0..<4 {
            let store = index % 2 == 0 ? firstStore : secondStore
            store.searchLocal("thread-affinity-\(index)")
        }

        try await waitUntil(timeout: 2.0) {
            probe.finishedCallCount == 4
        }
        #expect(probe.operatingSystemThreadIDs.count == 1)
        #expect(probe.operatingSystemThreadNames == ["LogseqChatCore"])
    }
    #endif

    @Test @MainActor func searchLocalKeepsDurableCaptureVisible() async throws {
        let recorder = RequestRecorder()
        let store = LogseqChatStore { request in
            recorder.append(request)
            if request.contains("\"action\":\"searchLocal\"") {
                let uuid = latestSendUUID(in: recorder) ?? "local-search"
                return """
                {
                  "apiVersion": 1,
                  "ok": true,
                  "result": {
                    "revision": 1,
                    "query": "E2E capture",
                    "blocks": [{
                      "uuid": "\(uuid)",
                      "kind": "block",
                      "title": "E2E capture responsive",
                      "pageId": "journal/2026-08-13",
                      "createdAt": 1776000000000,
                      "updatedAt": 1776000000000,
                      "syncStatus": "pending"
                    }],
                    "selectedBlock": null,
                    "lastRefreshAt": null,
                    "graphName": "pat test",
                    "isSearching": true
                  },
                  "error": null
                }
                """
            }
            if request.contains("\"action\":\"send\"") {
                Thread.sleep(forTimeInterval: 0.25)
            }
            let uuid = latestSendUUID(in: recorder) ?? "local-search"
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 1,
                "query": "",
                "blocks": [{
                  "uuid": "\(uuid)",
                  "kind": "block",
                  "title": "E2E capture responsive",
                  "pageId": "journal/2026-08-13",
                  "createdAt": 1776000000000,
                  "updatedAt": 1776000000000,
                  "syncStatus": "pending"
                }],
                "selectedBlock": null,
                "lastRefreshAt": null,
                "graphName": "pat test",
                "isSearching": false
              },
              "error": null
            }
            """
        }

        store.send("E2E capture responsive")
        try await waitUntil {
            store.snapshot.blocks.first?.title == "E2E capture responsive"
        }

        store.searchLocal("E2E capture")

        try await waitUntil {
            recorder.all.contains { $0.contains("\"action\":\"searchLocal\"") }
                && store.snapshot.query == "E2E capture"
        }

        #expect(store.snapshot.blocks.map(\.title).contains("E2E capture responsive"))
    }

    @Test @MainActor func staleSendResponseDoesNotClearCurrentSearchQuery() async throws {
        let recorder = RequestRecorder()
        let store = LogseqChatStore { request in
            recorder.append(request)
            if request.contains("\"action\":\"send\"")
                || request.contains("\"action\":\"beginPendingSync\"") {
                if request.contains("\"action\":\"send\"") {
                    Thread.sleep(forTimeInterval: 0.15)
                    recorder.append("send-returned")
                }
                return """
                {
                  "apiVersion": 1,
                  "ok": true,
                  "result": {
                    "revision": 2,
                    "query": "",
                    "blocks": [
                      {
                        "uuid": "local-1",
                        "kind": "block",
                        "title": "E2E capture responsive",
                        "pageId": "journal/2026-08-13",
                        "createdAt": 1776000000000,
                        "updatedAt": 1776000000000,
                        "syncStatus": "pending"
                      }
                    ],
                    "selectedBlock": null,
                    "lastRefreshAt": 1776000000000,
                    "graphName": "pat test",
                    "isSearching": false
                  },
                  "error": null
                }
                """
            }
            if request.contains("\"action\":\"searchLocal\"") {
                return """
                {
                  "apiVersion": 1,
                  "ok": true,
                  "result": {
                    "revision": 1,
                    "query": "E2E capture",
                    "blocks": [],
                    "selectedBlock": null,
                    "lastRefreshAt": null,
                    "graphName": "pat test",
                    "isSearching": true
                  },
                  "error": null
                }
                """
            }
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 1,
                "query": "",
                "blocks": [],
                "selectedBlock": null,
                "lastRefreshAt": null,
                "graphName": "pat test",
                "isSearching": false
              },
              "error": null
            }
            """
        }

        store.send("E2E capture responsive")
        store.searchLocal("E2E capture")

        try await waitUntil {
            recorder.all.contains { $0.contains("\"action\":\"searchLocal\"") }
                && store.snapshot.query == "E2E capture"
        }

        try await waitUntil(timeout: 2.0) {
            recorder.all.contains("send-returned")
        }
        try await waitUntil(timeout: 2.0) {
            store.snapshot.blocks.map(\.title).contains("E2E capture responsive")
        }

        #expect(store.snapshot.query == "E2E capture")
        #expect(store.snapshot.isSearching == true)
        #expect(store.snapshot.blocks.map(\.title).contains("E2E capture responsive"))
    }

    @Test @MainActor func sectionsDisplayJournalsByDayAndBlocksByOutlinerOrder() async throws {
        let store = LogseqChatStore { _ in
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 1,
                "query": "",
                "blocks": [
                  {
                    "uuid": "new",
                    "kind": "block",
                    "title": "Newer",
                    "pageId": "journal-today",
                    "parentId": "journal-today",
                    "order": "a2",
                    "createdAt": 1776000200000,
                    "updatedAt": 1776000200000,
                    "journalTitle": "Apr 13th, 2026",
                    "journalDay": 20260413
                  },
                  {
                    "uuid": "yesterday",
                    "kind": "block",
                    "title": "Yesterday",
                    "pageId": "journal-yesterday",
                    "parentId": "journal-yesterday",
                    "order": "a0",
                    "createdAt": 1775910000000,
                    "updatedAt": 1775910000000,
                    "journalTitle": "Apr 12th, 2026",
                    "journalDay": 20260412
                  },
                  {
                    "uuid": "old",
                    "kind": "block",
                    "title": "Older",
                    "pageId": "journal-today",
                    "parentId": "journal-today",
                    "order": "a1",
                    "createdAt": 1776000000000,
                    "updatedAt": 1776000000000,
                    "journalTitle": "Apr 13th, 2026",
                    "journalDay": 20260413
                  }
                ],
                "selectedBlock": null,
                "lastRefreshAt": 1776000200000,
                "isSearching": false
              },
              "error": null
            }
            """
        }

        store.search("")

        try await waitUntil {
            let blockIDs = store.sections.flatMap { $0.blocks }.map { $0.uuid }
            return blockIDs.count == 3
        }

        let blockIDs = store.sections.flatMap { $0.blocks }.map { $0.uuid }
        #expect(blockIDs.count == 3)
        #expect(blockIDs[0] == "yesterday")
        #expect(blockIDs[1] == "old")
        #expect(blockIDs[2] == "new")
        #expect(store.sections.count == 2)
        #expect(store.sections.first?.blocks.map(\.uuid) == ["yesterday"])
        #expect(store.sections.last?.blocks.map(\.uuid) == ["old", "new"])
    }

    @Test @MainActor func sectionsUseJournalMetadataWithoutRenderingJournalPages() async throws {
        let store = LogseqChatStore { _ in
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 1,
                "query": "",
                "blocks": [
                  {
                    "uuid": "today-new",
                    "kind": "block",
                    "title": "Today new",
                    "pageId": "journal-today",
                    "createdAt": 300,
                    "updatedAt": 300,
                    "journalTitle": "Aug 13th, 2026",
                    "journalDay": 20260813
                  },
                  {
                    "uuid": "yesterday",
                    "kind": "block",
                    "title": "Yesterday",
                    "pageId": "journal-yesterday",
                    "createdAt": 200,
                    "updatedAt": 200,
                    "journalTitle": "Aug 12th, 2026",
                    "journalDay": 20260812
                  },
                  {
                    "uuid": "today-old",
                    "kind": "block",
                    "title": "Today old",
                    "pageId": "journal-today",
                    "createdAt": 100,
                    "updatedAt": 100,
                    "journalTitle": "Aug 13th, 2026",
                    "journalDay": 20260813
                  }
                ],
                "selectedBlock": null,
                "lastRefreshAt": 300,
                "graphName": "pat test",
                "isSearching": false
              },
              "error": null
            }
            """
        }

        store.search("")
        try await waitUntil { store.snapshot.blocks.count == 3 }

        #expect(store.sections.count == 2)
        #expect(store.sections[0].id == "20260812")
        #expect(store.sections[0].blocks.map(\.uuid) == ["yesterday"])
        #expect(store.sections[1].title == "Aug 13th, 2026")
        #expect(store.sections[1].blocks.map(\.uuid) == ["today-old", "today-new"])
        #expect(store.sections.flatMap(\.blocks).allSatisfy { $0.kind == "block" })
    }

    @Test @MainActor func journalSectionsUsePageMembershipAndOutlinerPreorder() async throws {
        let store = LogseqChatStore { _ in
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 1,
                "query": "",
                "blocks": [
                  {
                    "uuid": "second-root",
                    "kind": "block",
                    "title": "Second root",
                    "pageId": "journal-today",
                    "parentId": "journal-today",
                    "order": "a2",
                    "createdAt": 100,
                    "updatedAt": 100,
                    "journalTitle": "Aug 15th, 2026",
                    "journalDay": 20260815
                  },
                  {
                    "uuid": "other-page",
                    "kind": "block",
                    "title": "Other page",
                    "pageId": "project-page",
                    "parentId": "project-page",
                    "order": "a0",
                    "createdAt": 500,
                    "updatedAt": 500
                  },
                  {
                    "uuid": "child",
                    "kind": "block",
                    "title": "Child",
                    "pageId": "journal-today",
                    "parentId": "first-root",
                    "order": "a0",
                    "createdAt": 300,
                    "updatedAt": 300,
                    "journalTitle": "Aug 15th, 2026",
                    "journalDay": 20260815
                  },
                  {
                    "uuid": "first-root",
                    "kind": "block",
                    "title": "First root",
                    "pageId": "journal-today",
                    "parentId": "journal-today",
                    "order": "a1",
                    "createdAt": 400,
                    "updatedAt": 400,
                    "journalTitle": "Aug 15th, 2026",
                    "journalDay": 20260815
                  }
                ],
                "selectedBlock": null,
                "lastRefreshAt": 500,
                "graphName": "sync 2",
                "isSearching": false
              },
              "error": null
            }
            """
        }

        store.search("")
        try await waitUntil { store.snapshot.blocks.count == 4 }

        #expect(store.sections.count == 1)
        #expect(store.sections[0].blocks.map(\.uuid) == ["first-root", "child", "second-root"])
        #expect(store.sections[0].blocks.map(\.order) == ["a1", "a0", "a2"])
    }

}

private actor SuspendedPendingTransport {
    private var continuation: CheckedContinuation<Void, Never>?
    private var cancelled = false

    var hasStarted: Bool { continuation != nil }
    var isWaiting: Bool { continuation != nil }
    var wasCancelled: Bool { cancelled }

    func send(_ request: LogseqPendingSyncRequest) async -> LogseqPendingSyncResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.cancel() }
        }
        if cancelled {
            return LogseqPendingSyncResult(status: nil, body: nil, error: "cancelled")
        }
        return LogseqPendingSyncResult(status: 201, body: #"{"uuid":"local-1"}"#, error: nil)
    }

    func resume() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: ())
    }

    private func cancel() {
        cancelled = true
        resume()
    }
}

private func pendingPumpSnapshot(
    query: String,
    syncStatus: String,
    request: LogseqPendingSyncRequest?
) -> String {
    let requestJSON: String
    if let request,
       let data = try? JSONEncoder().encode(request),
       let json = String(data: data, encoding: .utf8) {
        requestJSON = json
    } else {
        requestJSON = "null"
    }
    return """
    {
      "apiVersion": 1,
      "ok": true,
      "result": {
        "revision": 1,
        "query": "\(query)",
        "blocks": [{
          "uuid": "local-1",
          "kind": "block",
          "title": "Offline capture",
          "pageId": "journal/2026-08-13",
          "createdAt": 1776000000000,
          "updatedAt": 1776000000000,
          "syncStatus": "\(syncStatus)"
        }],
        "selectedBlock": null,
        "lastRefreshAt": 1776000000000,
        "graphName": "Test",
        "isSearching": \(!query.isEmpty),
        "pendingSyncRequest": \(requestJSON)
      },
      "error": null
    }
    """
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var first: String? {
        lock.lock()
        defer { lock.unlock() }
        return values.first
    }

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

private final class CoreCallConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let failingAction: String?
    private let callDelay: TimeInterval
    private var activeCalls = 0
    private var maximumActiveCalls = 0
    private var recordedEvents: [String] = []
    private var recordedOperatingSystemThreadIDs: Set<UInt64> = []
    private var recordedOperatingSystemThreadNames: Set<String> = []

    init(failingAction: String? = nil, callDelay: TimeInterval = 0) {
        self.failingAction = failingAction
        self.callDelay = callDelay
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    var maximumConcurrentCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActiveCalls
    }

    var finishedCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents.count { $0.hasPrefix("finish ") }
    }

    var operatingSystemThreadIDs: Set<UInt64> {
        lock.lock()
        defer { lock.unlock() }
        return recordedOperatingSystemThreadIDs
    }

    var operatingSystemThreadNames: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return recordedOperatingSystemThreadNames
    }

    func call(_ request: String, delayingAction: String) -> String {
        let decoded = try? JSONDecoder().decode(TestRPCRequest.self, from: Data(request.utf8))
        let action = decoded?.params.action ?? decoded?.method ?? "unknown"

        lock.lock()
        activeCalls += 1
        maximumActiveCalls = max(maximumActiveCalls, activeCalls)
        recordedEvents.append("start \(action)")
        #if !SKIP
        recordedOperatingSystemThreadIDs.insert(UInt64(pthread_mach_thread_np(pthread_self())))
        recordedOperatingSystemThreadNames.insert(Thread.current.name ?? "")
        #endif
        lock.unlock()

        if action == delayingAction {
            Thread.sleep(forTimeInterval: 0.2)
        } else if callDelay > 0 {
            Thread.sleep(forTimeInterval: callDelay)
        }

        lock.lock()
        recordedEvents.append("finish \(action)")
        activeCalls -= 1
        lock.unlock()

        if action == failingAction {
            return #"{"apiVersion":1,"ok":false,"result":null,"error":{"code":"test_error","message":"Expected test failure"}}"#
        }
        let query = action == "searchLocal" ? (decoded?.params.payload ?? "") : ""
        return """
        {
          "apiVersion": 1,
          "ok": true,
          "result": {
            "revision": 1,
            "query": "\(query)",
            "blocks": [],
            "selectedBlock": null,
            "lastRefreshAt": null,
            "graphName": "probe",
            "isSearching": \(action == "searchLocal")
          },
          "error": null
        }
        """
    }
}

private struct TestRPCRequest: Decodable {
    let method: String
    let params: TestRPCParams
}

private struct TestRPCParams: Decodable {
    let action: String?
    let payload: String?
}

private struct TestSendPayload: Decodable {
    let uuid: String
}

private func latestSendUUID(in recorder: RequestRecorder) -> String? {
    for request in recorder.all.reversed() {
        guard request.contains("\"action\":\"send\"") else { continue }
        if let uuid = extractSendUUID(from: request) {
            return uuid
        }
    }
    return nil
}

private func extractSendUUID(from request: String) -> String? {
    let escapedMarker = "\\\"uuid\\\":\\\""
    if let uuid = extractValue(from: request, after: escapedMarker, before: "\\\"") {
        return uuid
    }

    let marker = "\"uuid\":\""
    return extractValue(from: request, after: marker, before: "\"")
}

private func extractValue(from text: String, after marker: String, before terminator: String) -> String? {
    let parts = text.components(separatedBy: marker)
    guard parts.count > 1 else {
        return nil
    }
    let tailParts = parts[1].components(separatedBy: terminator)
    guard let value = tailParts.first, !value.isEmpty else {
        return nil
    }
    return value
}

@MainActor private func waitUntil(
    timeout: TimeInterval = 1.0,
    _ predicate: @escaping @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(predicate())
}

private func waitUntilAsync(
    timeout: TimeInterval = 1.0,
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await predicate() {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(await predicate())
}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
