import Foundation
#if !SKIP
import LogseqChatCoreABI
#endif

public struct LogseqGraphSnapshotArtifact: Sendable {
    public let metadataBody: String
    public let filePath: String
}

#if !SKIP
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
        let (metadataData, metadataResponse) = try await URLSession.shared.data(for: metadataRequest)
        try requireSuccess(metadataResponse)
        let metadata = try JSONDecoder().decode(SnapshotDownloadMetadata.self, from: metadataData)
        guard metadata.ok, let downloadURL = URL(string: metadata.url, relativeTo: metadataRequest.url) else {
            throw URLError(.cannotParseResponse)
        }
        var downloadRequest = URLRequest(url: downloadURL.absoluteURL)
        downloadRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (temporaryURL, downloadResponse) = try await URLSession.shared.download(for: downloadRequest)
        try requireSuccess(downloadResponse)
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
            guard let metadataBody = String(data: metadataData, encoding: .utf8) else {
                try? FileManager.default.removeItem(at: snapshotURL)
                throw URLError(.cannotDecodeContentData)
            }
            return LogseqGraphSnapshotArtifact(metadataBody: metadataBody, filePath: snapshotURL.path)
        } catch {
            try? FileManager.default.removeItem(at: ownedDownloadURL)
            throw error
        }
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
