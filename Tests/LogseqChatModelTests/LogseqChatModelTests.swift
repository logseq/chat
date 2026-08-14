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

@Suite struct LogseqChatModelTests {

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

    @Test @MainActor func taskAndAssetCreationAreOptimistic() async throws {
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
        let localAsset = try #require(store.snapshot.blocks.first { $0.kind == "asset" })
        #expect(UUID(uuidString: localAsset.uuid) != nil)
        #expect(store.snapshot.blocks.contains { $0.kind == "task" && $0.title == "Follow up" })
        #expect(store.snapshot.blocks.contains { $0.kind == "asset" && $0.localPath == "/documents/photo.jpg" })
        try await waitUntil {
            recorder.all.contains { $0.contains("\"action\":\"sendTask\"") }
                && recorder.all.contains { $0.contains("\"action\":\"addAsset\"") }
        }
        let assetRequest = try #require(
            recorder.all.last { $0.contains("\"action\":\"addAsset\"") }
        )
        #expect(extractSendUUID(from: assetRequest) == localAsset.uuid)
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
                && requests.contains { $0.contains("\"action\":\"syncPending\"") }
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

    @Test @MainActor func sendOptimisticallyPublishesPendingBlockBeforeSyncing() async throws {
        let recorder = RequestRecorder()
        let store = LogseqChatStore { request in
            recorder.append(request)
            let uuid = latestSendUUID(in: recorder) ?? "local-1"
            if request.contains("\"action\":\"syncPending\"") {
                return """
                {
                  "apiVersion": 1,
                  "ok": true,
                  "result": {
                    "revision": 2,
                    "query": "",
                    "blocks": [
                      {
                        "uuid": "\(uuid)",
                        "kind": "block",
                        "title": "Offline capture",
                        "pageId": "journal/2026-08-13",
                        "createdAt": 1776000000000,
                        "updatedAt": 1776000000000,
                        "syncStatus": "synced"
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
                    "title": "Offline capture",
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

        store.send("Offline capture")

        #expect(store.snapshot.blocks.count == 1)
        #expect(store.snapshot.blocks.first?.title == "Offline capture")
        #expect(store.snapshot.blocks.first?.isPendingSync == true)

        try await waitUntil {
            recorder.first?.contains("\"action\":\"send\"") == true
        }

        try await waitUntil {
            recorder.all.contains { $0.contains("\"action\":\"syncPending\"") }
                && store.snapshot.blocks.first?.isPendingSync == false
        }

        let requests = recorder.all
        #expect(requests.contains { $0.contains("\"action\":\"syncPending\"") })
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
        #expect(store.snapshot.blocks.first?.title == "Slow local capture")
        #expect(store.snapshot.blocks.first?.isPendingSync == true)
        try await waitUntil {
            recorder.first?.contains("\"action\":\"send\"") == true
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

    @Test @MainActor func refreshAndSyncForBackgroundWaitsForCoreActions() async throws {
        let recorder = RequestRecorder()
        let store = LogseqChatStore { request in
            recorder.append(request)
            if request.contains("\"action\":\"refresh\"") {
                Thread.sleep(forTimeInterval: 0.15)
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
                    "uuid": "remote-1",
                    "kind": "block",
                    "title": "Remote background block",
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

        let start = Date()
        await store.refreshAndSyncForBackground()
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed >= 0.15)
        #expect(recorder.all.contains { $0.contains("\"action\":\"refresh\"") })
        #expect(recorder.all.contains { $0.contains("\"action\":\"syncPending\"") })
        #expect(store.snapshot.blocks.first?.title == "Remote background block")
    }

    @Test @MainActor func searchLocalKeepsOptimisticCaptureVisibleBeforeCoreSettles() async throws {
        let recorder = RequestRecorder()
        let store = LogseqChatStore { request in
            recorder.append(request)
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
        #expect(store.snapshot.blocks.first?.title == "E2E capture responsive")

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
            if request.contains("\"action\":\"send\"") {
                Thread.sleep(forTimeInterval: 0.15)
                recorder.append("send-returned")
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

        #expect(store.snapshot.query == "E2E capture")
        #expect(store.snapshot.isSearching == true)
        #expect(store.snapshot.blocks.map(\.title).contains("E2E capture responsive"))
    }

    @Test @MainActor func sectionsDisplayJournalBlocksOldestFirst() async throws {
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
                    "pageId": "page-1",
                    "createdAt": 1776000200000,
                    "updatedAt": 1776000200000
                  },
                  {
                    "uuid": "yesterday",
                    "kind": "block",
                    "title": "Yesterday",
                    "pageId": "page-1",
                    "createdAt": 1775910000000,
                    "updatedAt": 1775910000000
                  },
                  {
                    "uuid": "old",
                    "kind": "block",
                    "title": "Older",
                    "pageId": "page-1",
                    "createdAt": 1776000000000,
                    "updatedAt": 1776000000000
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

private struct TestRPCRequest: Decodable {
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

struct TestData : Codable, Hashable {
    var testModuleName: String
}
