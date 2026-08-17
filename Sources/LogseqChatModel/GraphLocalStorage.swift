import Foundation

public enum LogseqGraphLocalStorage {
    public static func directoryURL(databasePath: String, graphID: String) -> URL {
        #if SKIP
        let directoryName = graphID
        #else
        let directoryName = graphID.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #endif
        return URL(fileURLWithPath: databasePath)
            .deletingLastPathComponent()
            .appendingPathComponent("graphs", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func isDownloaded(databasePath: String, graphID: String) -> Bool {
        let directory = directoryURL(databasePath: databasePath, graphID: graphID)
        return FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("graph.sqlite").path
        ) && FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("sync.checkpoint").path
        )
    }

    public static func delete(databasePath: String, graphID: String) throws {
        let directory = directoryURL(databasePath: databasePath, graphID: graphID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}
