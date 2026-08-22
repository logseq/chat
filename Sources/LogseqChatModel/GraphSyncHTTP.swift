import Foundation
#if !SKIP
import LogseqChatCoreABI
#endif

public struct LogseqGraphSnapshotArtifact: Sendable {
    public let metadataBody: String
    public let filePath: String
}

#if !SKIP
enum LogseqGraphSSEFailurePolicy {
    static func shouldReport(_ error: Error, taskIsCancelled: Bool) -> Bool {
        guard !taskIsCancelled, !(error is CancellationError) else { return false }
        return (error as? URLError)?.code != .cancelled
    }
}

struct LogseqGraphSSETransportBuffer {
    private static let maximumFrameBytes = 64 * 1024 * 1024
    private static let lineFeedBoundary = Data([0x0a, 0x0a])
    private static let carriageReturnBoundary = Data([0x0d, 0x0a, 0x0d, 0x0a])
    private var bytes = Data()

    mutating func append(_ chunk: Data) throws -> [String] {
        bytes.append(chunk)
        guard bytes.count <= Self.maximumFrameBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }

        var frames: [String] = []
        while let boundary = nextBoundary() {
            let frameData = bytes[..<boundary]
            guard let frame = String(data: frameData, encoding: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            frames.append(frame)
            bytes.removeSubrange(..<boundary)
        }
        return frames
    }

    private func nextBoundary() -> Data.Index? {
        let lineFeed = bytes.range(of: Self.lineFeedBoundary)?.upperBound
        let carriageReturn = bytes.range(of: Self.carriageReturnBoundary)?.upperBound
        switch (lineFeed, carriageReturn) {
        case (let left?, let right?): return min(left, right)
        case (let boundary?, nil), (nil, let boundary?): return boundary
        case (nil, nil): return nil
        }
    }
}
#endif

public enum LogseqGraphSnapshotRefreshPolicy {
    public static func shouldRefresh(
        snapshotRequired: Bool,
        isEditingOutlinerBlock: Bool
    ) -> Bool {
        snapshotRequired && !isEditingOutlinerBlock
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

    public static func eventsRequest(
        baseURL: String, graphID: String, appliedServerT: Int, accessToken: String
    ) throws -> URLRequest {
        let eventsURL = try apiRoot(baseURL)
            .appendingPathComponent("sync")
            .appendingPathComponent(graphID)
            .appendingPathComponent("events")
        guard var components = URLComponents(url: eventsURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        components.queryItems = [URLQueryItem(name: "since", value: "\(appliedServerT)")]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
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
