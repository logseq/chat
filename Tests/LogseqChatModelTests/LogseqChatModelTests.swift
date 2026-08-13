import Testing
import Foundation
@testable import LogseqChatModel

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

    @Test func updateBlockTitleAppliesCoreSnapshot() throws {
        let block = LogseqBlock(
            uuid: "block-1",
            kind: "block",
            title: "Draft title",
            pageId: "page-1",
            parentId: nil,
            createdAt: 1_776_000_000_000,
            updatedAt: 1_776_000_000_000
        )
        var capturedRequest = ""
        let store = LogseqChatStore { request in
            capturedRequest = request
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

        #expect(capturedRequest.contains("\"action\":\"updateBlock\""))
        #expect(capturedRequest.contains("\\\"uuid\\\":\\\"block-1\\\""))
        #expect(capturedRequest.contains("\\\"title\\\":\\\"Published title\\\""))
        #expect(store.snapshot.blocks.first?.title == "Published title")
        #expect(store.snapshot.blocks.first?.updatedAt == 1_776_000_100_000)
    }

    @Test func sectionsDisplayBlocksChronologically() throws {
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

        store.refresh()

        #expect(store.sections.flatMap { $0.blocks }.map { $0.uuid } == ["old", "new"])
    }

}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
