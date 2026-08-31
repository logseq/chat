import Foundation
#if !SKIP
import LogseqChatCoreABI
#endif

public struct LogseqGraphSnapshotArtifact: Sendable {
    public let metadataBody: String
    public let filePath: String
}

public enum LogseqGraphWebSocketFailurePolicy {
    public static func shouldReport(_ error: Error, taskIsCancelled: Bool) -> Bool {
        guard !taskIsCancelled, !(error is CancellationError) else { return false }
        return (error as? URLError)?.code != .cancelled
    }

    public static func userFacingMessage(_ error: Error) -> String {
        guard let urlError = error as? URLError else {
            return error.localizedDescription
        }
        switch urlError.code {
        case .timedOut:
            return "The sync server timed out. Check that it is running and reachable, then try again."
        case .notConnectedToInternet:
            return "No network connection. Sync will resume automatically when the network is available."
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost:
            return "The sync server is unreachable. Check that it is running and reachable."
        case .badURL, .unsupportedURL:
            return "The sync server address is invalid."
        default:
            return urlError.localizedDescription
        }
    }
}


public enum LogseqGraphWebSocketProtocol {
    public static func entityPullMessage(since: Int) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: ["since": since, "type": "entity/pull"],
            options: [.sortedKeys]
        )
        guard let message = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotParseResponse)
        }
        return message
    }
}

public enum LogseqGraphWebSocketReconnectPolicy {
    public static func delaySeconds(attempt: Int) -> Int {
        let seconds: Int
        switch min(max(attempt, 0), 5) {
        case 0: seconds = 1
        case 1: seconds = 2
        case 2: seconds = 4
        case 3: seconds = 8
        case 4: seconds = 16
        default: seconds = 30
        }
        return seconds
    }

    public static func shouldReconnect(_ error: LogseqChatCoreError?) -> Bool {
        error?.code == "websocket_connection_failed"
    }
}

public enum LogseqGraphSnapshotRefreshPolicy {
    public static func shouldRefresh(
        snapshotRequired: Bool,
        isEditingOutlinerBlock: Bool
    ) -> Bool {
        snapshotRequired && !isEditingOutlinerBlock
    }

    public static func shouldApplyDownloadedSnapshot(
        forceSnapshot: Bool,
        isEditingOutlinerBlock: Bool,
        hasPendingLocalChanges: Bool
    ) -> Bool {
        _ = hasPendingLocalChanges
        return !forceSnapshot || !isEditingOutlinerBlock
    }
}

public enum LogseqOutlinerAutosavePolicy {
    public static func serverSyncDelayNanoseconds(eventType: String) -> UInt64 {
        switch eventType {
        case "textChanged", "returnPressed", "backspacePressed":
            return UInt64(1_000_000_000)
        default:
            return UInt64(150_000_000)
        }
    }
}

public enum LogseqPendingSyncPumpPolicy {
    public static func shouldRestartAfterFinishing(
        requestedWhileFinishing: Bool
    ) -> Bool {
        requestedWhileFinishing
    }
}

public enum LogseqGraphSyncHTTP {
    private static func apiRoot(_ baseURL: String) throws -> URL {
        guard var root = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw URLError(.badURL)
        }
        if root.path.hasSuffix("/api") {
            root.deleteLastPathComponent()
        }
        return root
    }

    public static func snapshotMetadataRequest(
        baseURL: String, graphID: String, accessToken: String
    ) throws -> URLRequest {
        let root = try apiRoot(baseURL)
        let url = root
            .appendingPathComponent("sync")
            .appendingPathComponent(graphID)
            .appendingPathComponent("snapshot")
            .appendingPathComponent("download")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    public static func snapshotCursorRequest(
        baseURL: String, graphID: String, accessToken: String
    ) throws -> URLRequest {
        let url = try apiRoot(baseURL)
            .appendingPathComponent("sync")
            .appendingPathComponent(graphID)
            .appendingPathComponent("pull")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    public static func webSocketRequest(
        baseURL: String, graphID: String, accessToken: String
    ) throws -> URLRequest {
        let socketURL = try apiRoot(baseURL)
            .appendingPathComponent("sync")
            .appendingPathComponent(graphID)
        guard var components = URLComponents(url: socketURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        case "ws", "wss": break
        default: throw URLError(.unsupportedURL)
        }
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    #if !SKIP
    public static func downloadSnapshot(
        baseURL: String, graphID: String, accessToken: String
    ) async throws -> LogseqGraphSnapshotArtifact {
        let metadataRequest = try snapshotMetadataRequest(
            baseURL: baseURL, graphID: graphID, accessToken: accessToken
        )
        let cursorRequest = try snapshotCursorRequest(
            baseURL: baseURL, graphID: graphID, accessToken: accessToken
        )
        async let metadataResult = URLSession.shared.data(for: metadataRequest)
        async let cursorResult = URLSession.shared.data(for: cursorRequest)
        let (metadataData, metadataResponse) = try await metadataResult
        let (cursorData, cursorResponse) = try await cursorResult
        try requireSuccess(metadataResponse)
        try requireSuccess(cursorResponse)
        let metadata = try JSONDecoder().decode(SnapshotDownloadMetadata.self, from: metadataData)
        guard metadata.ok, let downloadURL = URL(string: metadata.url, relativeTo: metadataRequest.url) else {
            throw URLError(.cannotParseResponse)
        }
        var downloadRequest = URLRequest(url: downloadURL.absoluteURL)
        downloadRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (temporaryURL, downloadResponse) = try await URLSession.shared.download(for: downloadRequest)
        try requireSuccess(downloadResponse)
        guard let http = downloadResponse as? HTTPURLResponse,
              let rowCountText = http.value(forHTTPHeaderField: "x-snapshot-row-count"),
              let rowCount = Int(rowCountText), rowCount >= 0,
              let snapshotMetadataBody = String(data: metadataData, encoding: .utf8),
              let pullBody = String(data: cursorData, encoding: .utf8) else {
            throw URLError(.cannotParseResponse)
        }
        let ownedDownloadURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("logseq-graph-\(UUID().uuidString).download")
        try FileManager.default.moveItem(at: temporaryURL, to: ownedDownloadURL)
        do {
            let snapshotURL = try decodeSnapshotFile(
                at: ownedDownloadURL,
                contentEncoding: metadata.contentEncoding
            )
            if snapshotURL != ownedDownloadURL {
                try? FileManager.default.removeItem(at: ownedDownloadURL)
            }
            let metadataBody = try importMetadataBody(
                snapshotMetadataBody: snapshotMetadataBody,
                pullBody: pullBody,
                rowCount: rowCount
            )
            return LogseqGraphSnapshotArtifact(metadataBody: metadataBody, filePath: snapshotURL.path)
        } catch {
            try? FileManager.default.removeItem(at: ownedDownloadURL)
            throw error
        }
    }

    static func importMetadataBody(
        snapshotMetadataBody: String,
        pullBody: String,
        rowCount: Int
    ) throws -> String {
        guard rowCount >= 0,
              var metadata = try JSONSerialization.jsonObject(
                with: Data(snapshotMetadataBody.utf8)
              ) as? [String: Any],
              metadata["ok"] as? Bool == true,
              let serverSchemaVersion = metadata["schema-version"] as? String,
              !serverSchemaVersion.isEmpty,
              let pull = try JSONSerialization.jsonObject(
                with: Data(pullBody.utf8)
              ) as? [String: Any],
              pull["type"] as? String == "pull/ok",
              let cursor = pull["t"] as? Int,
              cursor >= 0 else {
            throw URLError(.cannotParseResponse)
        }
        metadata["t"] = cursor
        metadata["row-count"] = rowCount
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        guard let result = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        return result
    }

    static func decodeSnapshotFile(at inputURL: URL, contentEncoding: String?) throws -> URL {
        guard let contentEncoding else { return inputURL }
        let normalizedEncoding = contentEncoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedEncoding != "identity" else { return inputURL }
        guard normalizedEncoding == "gzip" else {
            throw SnapshotDecodingError.unsupportedEncoding(contentEncoding)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("logseq-graph-\(UUID().uuidString).snapshot")
        let result = inputURL.path.withCString { inputPath in
            outputURL.path.withCString { outputPath in
                logseq_chat_gunzip_file(inputPath, outputPath)
            }
        }
        guard result == 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw SnapshotDecodingError.gzipFailed(result)
        }
        return outputURL
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private struct SnapshotDownloadMetadata: Decodable {
        let ok: Bool
        let url: String
        let contentEncoding: String?

        private enum CodingKeys: String, CodingKey {
            case ok
            case url
            case contentEncoding = "content-encoding"
        }
    }

    private enum SnapshotDecodingError: LocalizedError {
        case unsupportedEncoding(String)
        case gzipFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .unsupportedEncoding(let encoding):
                return "Unsupported snapshot content encoding: \(encoding)"
            case .gzipFailed(let code):
                return "Could not decompress gzip snapshot (zlib error \(code))"
            }
        }
    }
    #endif
}
