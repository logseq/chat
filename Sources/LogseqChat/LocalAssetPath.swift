#if !SKIP
import Foundation

enum LocalAssetPath {
    private static let assetsDirectoryName = "Assets"

    static func storedPath(
        _ path: String,
        documentsDirectory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    ) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let assetsDirectory = documentsDirectory
            .appendingPathComponent(assetsDirectoryName, isDirectory: true)
            .standardizedFileURL
        guard url.deletingLastPathComponent() == assetsDirectory else { return path }
        return assetsDirectoryName + "/" + url.lastPathComponent
    }

    static func resolve(
        _ path: String,
        documentsDirectory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
        fileManager: FileManager = .default
    ) -> URL? {
        guard !path.isEmpty else { return nil }

        let storedURL = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : documentsDirectory.appendingPathComponent(path)
        if fileManager.fileExists(atPath: storedURL.path) {
            return storedURL
        }

        let relocatedURL = documentsDirectory
            .appendingPathComponent(assetsDirectoryName, isDirectory: true)
            .appendingPathComponent(storedURL.lastPathComponent)
        return fileManager.fileExists(atPath: relocatedURL.path) ? relocatedURL : nil
    }
}
#endif
