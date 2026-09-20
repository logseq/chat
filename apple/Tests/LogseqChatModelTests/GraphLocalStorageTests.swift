import Foundation
import Testing
@testable import LogseqChatModel

@Suite struct GraphLocalStorageTests {
    @Test func graphDirectoryMatchesTheSnapshotStorageLayout() {
        let databasePath = "/tmp/logseq/catalog.sqlite"

        let directory = LogseqGraphLocalStorage.directoryURL(
            databasePath: databasePath,
            graphID: "graph id/一"
        )

        #expect(directory.path == "/tmp/logseq/graphs/graph%20id%2F%E4%B8%80")
    }

    @Test func downloadedGraphRequiresBothDatabaseAndCheckpoint() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("logseq-graph-storage-\(UUID().uuidString)", isDirectory: true)
        let databasePath = root.appendingPathComponent("catalog.sqlite").path
        let directory = LogseqGraphLocalStorage.directoryURL(
            databasePath: databasePath,
            graphID: "graph-1"
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(!LogseqGraphLocalStorage.isDownloaded(databasePath: databasePath, graphID: "graph-1"))
        try Data().write(to: directory.appendingPathComponent("graph.sqlite"))
        #expect(!LogseqGraphLocalStorage.isDownloaded(databasePath: databasePath, graphID: "graph-1"))
        try Data().write(to: directory.appendingPathComponent("sync.checkpoint"))
        #expect(LogseqGraphLocalStorage.isDownloaded(databasePath: databasePath, graphID: "graph-1"))
    }

    @Test func deletingALocalGraphRemovesOnlyItsDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("logseq-graph-delete-\(UUID().uuidString)", isDirectory: true)
        let databasePath = root.appendingPathComponent("catalog.sqlite").path
        let target = LogseqGraphLocalStorage.directoryURL(databasePath: databasePath, graphID: "target")
        let neighbor = LogseqGraphLocalStorage.directoryURL(databasePath: databasePath, graphID: "neighbor")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: neighbor, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try LogseqGraphLocalStorage.delete(databasePath: databasePath, graphID: "target")

        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(FileManager.default.fileExists(atPath: neighbor.path))
        try LogseqGraphLocalStorage.delete(databasePath: databasePath, graphID: "target")
    }
}
