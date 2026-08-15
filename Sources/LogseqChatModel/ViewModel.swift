import Foundation
import Observation
#if !os(Android)
import OSLog
#endif
#if SKIP
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
#endif
import SkipFFI
#if !SKIP
import LogseqChatCoreABI
#endif

private struct LogseqModelLogger {
    #if !os(Android)
    private let logger = Logger(subsystem: "logseq.chat.model", category: "LogseqChatModel")
    #endif

    func info(_ message: String) {
        #if os(Android)
        print(message)
        #else
        logger.info("\(message, privacy: .public)")
        #endif
    }

    func error(_ message: String) {
        #if os(Android)
        print(message)
        #else
        logger.error("\(message, privacy: .public)")
        #endif
    }
}

private let logger = LogseqModelLogger()

public final class LogseqChatCore {
    nonisolated(unsafe) public static let shared = registerNatives(
        LogseqChatCore(),
        frameworkName: "LogseqChat",
        libraryName: "logseq_chat_core"
    )

    private init() {
    }

    public func initialize() {
        #if LOGSEQ_CHAT_CORE
        LogseqChatCoreABI.logseq_chat_initialize()
        #endif
    }

    /* SKIP EXTERN */ public func logseq_chat_call(_ request: String) -> String {
        #if LOGSEQ_CHAT_CORE
        return String(cString: LogseqChatCoreABI.logseq_chat_call(request))
        #else
        return
            """
            {
              "apiVersion": 1,
              "ok": false,
              "result": null,
              "error": {
                "code": "native_core_unlinked",
                "message": "Build with the OCaml DataScript core and LOGSEQ_CHAT_CORE"
              }
            }
            """
        #endif
    }
}

public struct LogseqEntitySummary: Codable, Hashable, Identifiable, Sendable {
    public let uuid: String
    public let kind: String
    public let title: String
    public var id: String { uuid }
}

public struct LogseqIcon: Codable, Hashable, Sendable {
    public let type: String
    public let id: String
    public let color: String?

    public init(type: String, id: String, color: String? = nil) {
        self.type = type
        self.id = id
        self.color = color
    }
}

public struct LogseqTaskStatus: Codable, Hashable, Identifiable, Sendable {
    public let uuid: String
    public let ident: String?
    public let title: String
    public let icon: LogseqIcon?
    public var id: String { uuid }

    public static let backlog = LogseqTaskStatus(
        uuid: "backlog", ident: "logseq.property/status.backlog", title: "Backlog",
        icon: LogseqIcon(type: "tabler-icon", id: "Backlog")
    )
    public static let todo = LogseqTaskStatus(
        uuid: "todo", ident: "logseq.property/status.todo", title: "Todo",
        icon: LogseqIcon(type: "tabler-icon", id: "Todo")
    )
    public static let doing = LogseqTaskStatus(
        uuid: "doing", ident: "logseq.property/status.doing", title: "Doing",
        icon: LogseqIcon(type: "tabler-icon", id: "InProgress50")
    )
    public static let inReview = LogseqTaskStatus(
        uuid: "in-review", ident: "logseq.property/status.in-review", title: "In Review",
        icon: LogseqIcon(type: "tabler-icon", id: "InReview")
    )
    public static let done = LogseqTaskStatus(
        uuid: "done", ident: "logseq.property/status.done", title: "Done",
        icon: LogseqIcon(type: "tabler-icon", id: "Done")
    )
    public static let canceled = LogseqTaskStatus(
        uuid: "canceled", ident: "logseq.property/status.canceled", title: "Canceled",
        icon: LogseqIcon(type: "tabler-icon", id: "Cancelled")
    )

    public static let builtIn = [backlog, todo, doing, inReview, done, canceled]
}

public struct LogseqBlock: Codable, Identifiable, Hashable {
    public let uuid: String
    public let kind: String
    public let title: String
    public let pageId: String
    public let parentId: String?
    public let order: String?
    public let createdAt: Int64
    public let updatedAt: Int64
    public let syncStatus: String?
    public let journalTitle: String?
    public let journalDay: Int?
    public let tags: [LogseqEntitySummary]
    public let references: [LogseqEntitySummary]
    public let status: LogseqTaskStatus?
    public let assetType: String?
    public let assetSize: Int?
    public let assetChecksum: String?
    public let localPath: String?

    public init(
        uuid: String,
        kind: String,
        title: String,
        pageId: String,
        parentId: String?,
        order: String? = nil,
        createdAt: Int64,
        updatedAt: Int64,
        syncStatus: String?,
        journalTitle: String? = nil,
        journalDay: Int? = nil,
        tags: [LogseqEntitySummary] = [],
        references: [LogseqEntitySummary] = [],
        status: LogseqTaskStatus? = nil,
        assetType: String? = nil,
        assetSize: Int? = nil,
        assetChecksum: String? = nil,
        localPath: String? = nil
    ) {
        self.uuid = uuid
        self.kind = kind
        self.title = title
        self.pageId = pageId
        self.parentId = parentId
        self.order = order
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.syncStatus = syncStatus
        self.journalTitle = journalTitle
        self.journalDay = journalDay
        self.tags = tags
        self.references = references
        self.status = status
        self.assetType = assetType
        self.assetSize = assetSize
        self.assetChecksum = assetChecksum
        self.localPath = localPath
    }

    private enum CodingKeys: String, CodingKey {
        case uuid, kind, title, pageId, parentId, order, createdAt, updatedAt, syncStatus
        case journalTitle, journalDay, tags, references, status, assetType, assetSize
        case assetChecksum, localPath
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try values.decode(String.self, forKey: .uuid)
        kind = try values.decode(String.self, forKey: .kind)
        title = try values.decode(String.self, forKey: .title)
        pageId = try values.decode(String.self, forKey: .pageId)
        parentId = try values.decodeIfPresent(String.self, forKey: .parentId)
        order = try values.decodeIfPresent(String.self, forKey: .order)
        createdAt = try values.decode(Int64.self, forKey: .createdAt)
        updatedAt = try values.decode(Int64.self, forKey: .updatedAt)
        syncStatus = try values.decodeIfPresent(String.self, forKey: .syncStatus)
        journalTitle = try values.decodeIfPresent(String.self, forKey: .journalTitle)
        journalDay = try values.decodeIfPresent(Int.self, forKey: .journalDay)
        tags = try values.decodeIfPresent([LogseqEntitySummary].self, forKey: .tags) ?? []
        references = try values.decodeIfPresent([LogseqEntitySummary].self, forKey: .references) ?? []
        status = try values.decodeIfPresent(LogseqTaskStatus.self, forKey: .status)
        assetType = try values.decodeIfPresent(String.self, forKey: .assetType)
        assetSize = try values.decodeIfPresent(Int.self, forKey: .assetSize)
        assetChecksum = try values.decodeIfPresent(String.self, forKey: .assetChecksum)
        localPath = try values.decodeIfPresent(String.self, forKey: .localPath)
    }

    public var id: String { uuid }
    public var isPendingSync: Bool { syncStatus == "pending" }
    public var isFailedSync: Bool { syncStatus == "failed" }

    public var createdDate: Date {
        Date(timeIntervalSince1970: Double(createdAt) / 1000.0)
    }

    public var dayTitle: String {
        if let journalTitle, !journalTitle.isEmpty {
            return journalTitle
        }
        return Self.dayFormatter.string(from: createdDate)
    }

    public var journalSectionID: String {
        if let journalDay {
            return String(journalDay)
        }
        return dayTitle
    }

    public var timeTitle: String {
        Self.timeFormatter.string(from: createdDate)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

public struct LogseqBlockSection: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let blocks: [LogseqBlock]
}

public struct LogseqGraph: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let isEncrypted: Bool
    public let isReady: Bool
}

public struct LogseqPendingSyncRequest: Codable, Sendable {
    public let id: Int
    public let method: String
    public let url: String
    public let body: String?
    public let token: String
    public let filePath: String?
    public let contentType: String

    public init(
        id: Int,
        method: String,
        url: String,
        body: String?,
        token: String,
        filePath: String?,
        contentType: String
    ) {
        self.id = id
        self.method = method
        self.url = url
        self.body = body
        self.token = token
        self.filePath = filePath
        self.contentType = contentType
    }
}

public struct LogseqPendingSyncResult: Codable, Sendable {
    public let status: Int?
    public let body: String?
    public let error: String?

    public init(status: Int?, body: String?, error: String?) {
        self.status = status
        self.body = body
        self.error = error
    }
}

private struct LogseqPendingSyncCompletion: Encodable {
    let id: Int
    let status: Int?
    let body: String?
    let error: String?
}

public struct LogseqChatSnapshot: Codable {
    public let revision: Int
    public let query: String
    public let blocks: [LogseqBlock]
    public let selectedBlock: LogseqBlock?
    public let lastRefreshAt: Int64?
    public let graphName: String?
    public let selectedGraphId: String?
    public let graphs: [LogseqGraph]?
    public let appliedServerT: Int?
    public let syncConnected: Bool?
    public let isSearching: Bool
    public let relatedBlocks: [LogseqBlock]?
    public let taskStatuses: [LogseqTaskStatus]?
    public let isGraphEncrypted: Bool?
    public let isGraphUnlocked: Bool?
    public let pendingSyncRequest: LogseqPendingSyncRequest?

    public init(
        revision: Int, query: String, blocks: [LogseqBlock], selectedBlock: LogseqBlock?,
        lastRefreshAt: Int64?, graphName: String?, isSearching: Bool,
        selectedGraphId: String? = nil, graphs: [LogseqGraph]? = nil,
        appliedServerT: Int? = nil, syncConnected: Bool? = nil,
        relatedBlocks: [LogseqBlock]? = nil,
        taskStatuses: [LogseqTaskStatus]? = nil,
        isGraphEncrypted: Bool? = nil,
        isGraphUnlocked: Bool? = nil,
        pendingSyncRequest: LogseqPendingSyncRequest? = nil
    ) {
        self.revision = revision
        self.query = query
        self.blocks = blocks
        self.selectedBlock = selectedBlock
        self.lastRefreshAt = lastRefreshAt
        self.graphName = graphName
        self.selectedGraphId = selectedGraphId
        self.graphs = graphs
        self.appliedServerT = appliedServerT
        self.syncConnected = syncConnected
        self.isSearching = isSearching
        self.relatedBlocks = relatedBlocks
        self.taskStatuses = taskStatuses
        self.isGraphEncrypted = isGraphEncrypted
        self.isGraphUnlocked = isGraphUnlocked
        self.pendingSyncRequest = pendingSyncRequest
    }
}

public struct LogseqChatCoreError: Codable, Equatable {
    public let code: String
    public let message: String
}

public struct LogseqChatRPCResponse: Decodable {
    public let apiVersion: Int
    public let ok: Bool
    public let result: LogseqChatSnapshot?
    public let error: LogseqChatCoreError?
}

public struct LogseqChatRPCParams: Encodable {
    public let action: String?
    public let payload: String?
    public let path: String?

    public init(action: String?, payload: String? = nil, path: String? = nil) {
        self.action = action
        self.payload = payload
        self.path = path
    }
}

public struct LogseqChatRPCRequest: Encodable {
    public let apiVersion: Int
    public let method: String
    public let params: LogseqChatRPCParams

    public init(method: String, params: LogseqChatRPCParams) {
        self.apiVersion = 1
        self.method = method
        self.params = params
    }
}

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

private struct UpdateBlockPayload: Encodable {
    let uuid: String
    let title: String
    let status: TaskStatusPayload?
}

private struct UpdateBlockStatusPayload: Encodable {
    let uuid: String
    let status: TaskStatusPayload
}

private struct SendBlockPayload: Encodable {
    let text: String
    let uuid: String
    let now: Int64
}

private struct SendTaskPayload: Encodable {
    let text: String
    let uuid: String
    let now: Int64
    let status: TaskStatusPayload
}

private struct TaskStatusPayload: Encodable {
    let uuid: String
    let ident: String?
    let title: String
    let iconType: String?
    let iconId: String?
    let iconColor: String?
}

private struct AddAssetPayload: Encodable {
    let uuid: String
    let title: String
    let now: Int64
    let assetType: String
    let assetSize: Int
    let assetChecksum: String
    let localPath: String
}

private struct ImportSnapshotPayload: Encodable {
    let graphId: String
    let activePath: String
    let checkpointPath: String
    let metadataBody: String
    let downloadPath: String
    let isEncrypted: Bool
}

private struct OpenGraphPayload: Encodable {
    let graphId: String
    let activePath: String
    let checkpointPath: String
    let isEncrypted: Bool
}

private enum LogseqPendingSyncHTTPTransport {
    static func send(_ pending: LogseqPendingSyncRequest) async -> LogseqPendingSyncResult {
        #if SKIP
        return await AndroidPendingSyncTransport.send(request: pending)
        #else
        do {
            guard let url = URL(string: pending.url) else {
                return LogseqPendingSyncResult(status: nil, body: nil, error: "Invalid pending sync URL")
            }
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpMethod = pending.method
            request.setValue("Bearer \(pending.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(pending.contentType, forHTTPHeaderField: "Content-Type")
            let data: Data
            let response: URLResponse
            if let filePath = pending.filePath {
                (data, response) = try await URLSession.shared.upload(
                    for: request,
                    fromFile: URL(fileURLWithPath: filePath)
                )
            } else {
                request.httpBody = pending.body.map { Data($0.utf8) }
                (data, response) = try await URLSession.shared.data(for: request)
            }
            guard let http = response as? HTTPURLResponse else {
                return LogseqPendingSyncResult(status: nil, body: nil, error: "Pending sync response was not HTTP")
            }
            return LogseqPendingSyncResult(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "",
                error: nil
            )
        } catch {
            return LogseqPendingSyncResult(status: nil, body: nil, error: "\(error)")
        }
        #endif
    }
}

#if !SKIP
private final class LogseqChatCoreExecutor: @unchecked Sendable {
    static let shared = LogseqChatCoreExecutor()

    private struct Job: Sendable {
        let callCore: @Sendable (String) -> String
        let requestJSON: String
        let continuation: CheckedContinuation<String, Never>
    }

    private final class State: @unchecked Sendable {
        private let condition = NSCondition()
        private var jobs: [Job] = []

        func enqueue(_ job: Job) {
            condition.lock()
            jobs.append(job)
            condition.signal()
            condition.unlock()
        }

        func next() -> Job {
            condition.lock()
            while jobs.isEmpty {
                condition.wait()
            }
            let job = jobs.removeFirst()
            condition.unlock()
            return job
        }
    }

    private let state: State
    private let thread: Thread

    private init() {
        let state = State()
        self.state = state
        self.thread = Thread {
            Thread.current.name = "LogseqChatCore"
            LogseqChatCore.shared.initialize()
            while true {
                let job = state.next()
                job.continuation.resume(returning: job.callCore(job.requestJSON))
            }
        }
        thread.name = "LogseqChatCore"
        thread.start()
    }

    func call(
        _ callCore: @escaping @Sendable (String) -> String,
        requestJSON: String
    ) async -> String {
        await withCheckedContinuation { continuation in
            state.enqueue(Job(
                callCore: callCore,
                requestJSON: requestJSON,
                continuation: continuation
            ))
        }
    }
}
#endif

@MainActor @Observable public final class LogseqChatStore {
    public private(set) var snapshot = LogseqChatSnapshot(
        revision: 0,
        query: "",
        blocks: [],
        selectedBlock: nil,
        lastRefreshAt: nil,
        graphName: nil,
        isSearching: false,
        relatedBlocks: nil
    )
    public private(set) var lastError: LogseqChatCoreError?
    public private(set) var isRefreshing = false
    public private(set) var cursorAdvancedAfterMutation = false

    private let callCore: @Sendable (String) -> String
    private let pendingTransport: @Sendable (LogseqPendingSyncRequest) async -> LogseqPendingSyncResult
    private var searchGeneration = 0
    private var openedDatabasePath: String?
    private var mutationServerT: Int?
    private var pendingSyncTask: Task<Void, Never>?
    private var pendingSyncRequested = false

    public convenience init(call: @escaping @Sendable (String) -> String) {
        self.init(call: call) { request in
            await LogseqPendingSyncHTTPTransport.send(request)
        }
    }

    public init(
        call: @escaping @Sendable (String) -> String,
        pendingTransport: @escaping @Sendable (LogseqPendingSyncRequest) async -> LogseqPendingSyncResult
    ) {
        self.callCore = call
        self.pendingTransport = pendingTransport
    }

    public var sections: [LogseqBlockSection] {
        let visibleBlocks = snapshot.isSearching
            ? snapshot.blocks
            : snapshot.blocks.filter { $0.journalDay != nil }
        var blocksByJournal: [String: [LogseqBlock]] = [:]
        var titlesByJournal: [String: String] = [:]
        for block in visibleBlocks {
            blocksByJournal[block.journalSectionID, default: []].append(block)
            titlesByJournal[block.journalSectionID] = block.dayTitle
        }
        return blocksByJournal.map { id, blocks in
            let orderedBlocks = Self.outlinerPreorder(blocks, pageId: blocks.first?.pageId ?? "")
            return LogseqBlockSection(id: id, title: titlesByJournal[id] ?? id, blocks: orderedBlocks)
        }.sorted { left, right in
            if let leftDay = Int(left.id), let rightDay = Int(right.id), leftDay != rightDay {
                return leftDay < rightDay
            }
            return left.id < right.id
        }
    }

    private static func outlinerPreorder(_ blocks: [LogseqBlock], pageId: String) -> [LogseqBlock] {
        let blockIds = Set(blocks.map(\.uuid))
        var children: [String: [LogseqBlock]] = [:]
        for block in blocks {
            let parentId = block.parentId.flatMap { blockIds.contains($0) ? $0 : nil } ?? pageId
            children[parentId, default: []].append(block)
        }
        func sorted(_ siblings: [LogseqBlock]) -> [LogseqBlock] {
            siblings.sorted { left, right in
                if let leftOrder = left.order {
                    if let rightOrder = right.order, leftOrder != rightOrder {
                        return leftOrder < rightOrder
                    }
                    if right.order == nil {
                        return true
                    }
                } else if right.order != nil {
                    return false
                }
                if left.createdAt != right.createdAt {
                    return left.createdAt < right.createdAt
                }
                return left.uuid < right.uuid
            }
        }
        var visited = Set<String>()
        var result: [LogseqBlock] = []
        func appendChildren(of parentId: String) {
            for block in sorted(children[parentId] ?? []) where !visited.contains(block.uuid) {
                visited.insert(block.uuid)
                result.append(block)
                appendChildren(of: block.uuid)
            }
        }
        appendChildren(of: pageId)
        result.append(contentsOf: sorted(blocks.filter { !visited.contains($0.uuid) }))
        return result
    }

    public func open(path: String) {
        openedDatabasePath = path
        performAsync(LogseqChatRPCRequest(method: "open", params: LogseqChatRPCParams(action: nil, path: path)))
    }

    public func configure(
        baseURL: String, token: String, graphID: String? = nil,
        refreshAfterApply: Bool = true
    ) {
        let baseURL = Self.normalizedBaseURL(baseURL)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = """
        {"baseUrl":"\(Self.escape(baseURL))","graphId":"\(Self.escape(graphID ?? ""))","token":"\(Self.escape(token))"}
        """
        performAsync(LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "configure", payload: payload)), afterApply: {
            if refreshAfterApply {
                self.refreshSoon()
            }
        })
    }

    public func configureAndSelectGraph(
        baseURL: String, token: String, selectedGraphID: String?,
        refreshGraphCatalog: Bool = true
    ) async {
        let baseURL = Self.normalizedBaseURL(baseURL)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = """
        {"baseUrl":"\(Self.escape(baseURL))","graphId":"\(Self.escape(selectedGraphID ?? ""))","token":"\(Self.escape(token))"}
        """
        await performAsyncAndWait(
            LogseqChatRPCRequest(
                method: "dispatch",
                params: LogseqChatRPCParams(action: "configure", payload: payload)
            )
        )
        guard lastError == nil else { return }
        if selectedGraphID != nil {
            if refreshGraphCatalog && !token.isEmpty {
                await performAsyncAndWait(
                    LogseqChatRPCRequest(
                        method: "dispatch",
                        params: LogseqChatRPCParams(action: "refreshGraphCatalog")
                    )
                )
            }
            return
        }
        await performAsyncAndWait(
            LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "refresh"))
        )
        guard
            lastError == nil,
            let selectedGraphID,
            snapshot.graphs?.contains(where: { $0.id == selectedGraphID }) == true
        else { return }
        await performAsyncAndWait(
            LogseqChatRPCRequest(
                method: "dispatch",
                params: LogseqChatRPCParams(action: "selectGraph", payload: selectedGraphID)
            )
        )
    }

    public func refresh() {
        refresh(afterApply: nil)
    }

    public func selectGraph(_ graphID: String) {
        performAsync(
            LogseqChatRPCRequest(
                method: "dispatch",
                params: LogseqChatRPCParams(action: "selectGraph", payload: graphID)
            ),
            afterApply: nil
        )
    }

    public func unlockGraph(_ password: String) async {
        await performAsyncAndWait(
            LogseqChatRPCRequest(
                method: "dispatch",
                params: LogseqChatRPCParams(action: "unlockGraph", payload: password)
            )
        )
    }

    public func bootstrapSelectedGraph(
        graphID: String, baseURL: String, accessToken: String, forceSnapshot: Bool = false,
        allowSnapshotDownload: Bool = true, isEncrypted: Bool = false
    ) async -> Bool {
        guard let openedDatabasePath else {
            lastError = LogseqChatCoreError(code: "database_not_open", message: "Open local storage before syncing")
            return false
        }
        do {
            #if SKIP
            let graphDirectoryName = graphID
            #else
            let graphDirectoryName = graphID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? graphID
            #endif
            let graphDirectory = URL(fileURLWithPath: openedDatabasePath)
                .deletingLastPathComponent()
                .appendingPathComponent("graphs")
                .appendingPathComponent(graphDirectoryName)
            try FileManager.default.createDirectory(at: graphDirectory, withIntermediateDirectories: true)
            let activeURL = graphDirectory.appendingPathComponent("graph.sqlite")
            let checkpointURL = graphDirectory.appendingPathComponent("sync.checkpoint")
            let openPayload = OpenGraphPayload(
                graphId: graphID,
                activePath: activeURL.path,
                checkpointPath: checkpointURL.path,
                isEncrypted: isEncrypted
            )
            if !forceSnapshot,
               FileManager.default.fileExists(atPath: activeURL.path),
               FileManager.default.fileExists(atPath: checkpointURL.path) {
                await dispatchEncodedAndWait("openGraph", openPayload)
                if lastError == nil {
                    return true
                }
            }

            guard allowSnapshotDownload else { return false }

            #if SKIP
            let artifact = try await AndroidGraphSnapshotTransport.downloadSnapshot(
                baseURL: baseURL,
                graphID: graphID,
                accessToken: accessToken,
                workingDirectory: graphDirectory.path
            )
            #else
            let artifact = try await LogseqGraphSyncHTTP.downloadSnapshot(
                baseURL: baseURL, graphID: graphID, accessToken: accessToken
            )
            #endif
            defer { try? FileManager.default.removeItem(atPath: artifact.filePath) }
            let payload = ImportSnapshotPayload(
                graphId: graphID,
                activePath: activeURL.path,
                checkpointPath: checkpointURL.path,
                metadataBody: artifact.metadataBody,
                downloadPath: artifact.filePath,
                isEncrypted: isEncrypted
            )
            let payloadData = try JSONEncoder().encode(payload)
            guard let payloadString = String(data: payloadData, encoding: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            await performAsyncAndWait(
                LogseqChatRPCRequest(
                    method: "dispatch",
                    params: LogseqChatRPCParams(action: "importSnapshot", payload: payloadString)
                )
            )
            return lastError == nil
        } catch {
            lastError = LogseqChatCoreError(code: "snapshot_download_failed", message: "\(error)")
            return false
        }
    }

    public func runGraphEventsOnce(
        graphID: String, baseURL: String, accessToken: String,
        stopAfterFirstFrame: Bool = false
    ) async -> Bool {
        guard let cursor = snapshot.appliedServerT else {
            lastError = LogseqChatCoreError(code: "sync_cursor_missing", message: "Graph checkpoint is not open")
            return false
        }
        #if SKIP
        do {
            let stream = try await AndroidGraphSSETransport.open(
                baseURL: baseURL,
                graphID: graphID,
                appliedServerT: cursor,
                accessToken: accessToken
            )
            defer { stream.close() }
            await dispatchRawAndWait("startSSE")
            guard lastError == nil else { return false }
            while let frame = try await stream.nextFrame() {
                await dispatchRawAndWait("feedSSE", payload: frame)
                if lastError != nil { break }
                syncPending()
                if lastError != nil { break }
                if stopAfterFirstFrame { break }
            }
            let streamError = lastError
            await dispatchRawAndWait("stopSSE")
            if let streamError {
                lastError = streamError
                return streamError.code == "snapshot_required"
            }
        } catch {
            await dispatchRawAndWait("stopSSE")
            lastError = LogseqChatCoreError(code: "sse_connection_failed", message: "\(error)")
        }
        return false
        #else
        do {
            let request = try LogseqGraphSyncHTTP.eventsRequest(
                baseURL: baseURL,
                graphID: graphID,
                appliedServerT: cursor,
                accessToken: accessToken
            )
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            await dispatchRawAndWait("startSSE")
            guard lastError == nil else { return false }
            var transportBuffer = LogseqGraphSSETransportBuffer()
            var networkChunk = Data()
            networkChunk.reserveCapacity(16 * 1024)
            eventStream: for try await byte in bytes {
                if Task.isCancelled { break }
                networkChunk.append(byte)
                if byte == 0x0a || networkChunk.count == 16 * 1024 {
                    let frames = try transportBuffer.append(networkChunk)
                    networkChunk.removeAll(keepingCapacity: true)
                    for frame in frames {
                        await dispatchRawAndWait("feedSSE", payload: frame)
                        if lastError != nil { break }
                        syncPending()
                        if lastError != nil { break }
                        if stopAfterFirstFrame { break eventStream }
                    }
                    if lastError != nil { break }
                }
            }
            let streamError = lastError
            await dispatchRawAndWait("stopSSE")
            if let streamError {
                lastError = streamError
                return streamError.code == "snapshot_required"
            }
        } catch is CancellationError {
            await dispatchRawAndWait("stopSSE")
        } catch {
            await dispatchRawAndWait("stopSSE")
            lastError = LogseqChatCoreError(code: "sse_connection_failed", message: "\(error)")
        }
        return false
        #endif
    }

    private func dispatchEncodedAndWait<T: Encodable>(_ action: String, _ value: T) async {
        do {
            let data = try JSONEncoder().encode(value)
            guard let payload = String(data: data, encoding: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            await performAsyncAndWait(
                LogseqChatRPCRequest(
                    method: "dispatch",
                    params: LogseqChatRPCParams(action: action, payload: payload)
                )
            )
        } catch {
            lastError = LogseqChatCoreError(code: "request_encoding", message: "\(error)")
        }
    }

    private func dispatchRawAndWait(_ action: String, payload: String? = nil) async {
        await performAsyncAndWait(
            LogseqChatRPCRequest(
                method: "dispatch",
                params: LogseqChatRPCParams(action: action, payload: payload)
            )
        )
    }

    private func refresh(afterApply: (@MainActor () -> Void)?) {
        guard !isRefreshing else { return }
        isRefreshing = true
        performAsync(LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "refresh")), afterApply: {
            self.isRefreshing = false
            afterApply?()
        })
    }

    public func refreshSoon() {
        Task {
            await Task.yield()
            refresh(afterApply: {
                if self.lastError == nil {
                    self.syncPending()
                }
            })
        }
    }

    public func search(_ query: String) {
        searchGeneration += 1
        let generation = searchGeneration
        performAsync(
            LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "search", payload: query)),
            shouldApply: {
                self.searchGeneration == generation
            }
        )
    }

    public func searchLocal(_ query: String) {
        searchGeneration += 1
        let generation = searchGeneration
        performAsync(
            LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "searchLocal", payload: query)),
            shouldApply: {
                self.searchGeneration == generation
            }
        )
    }

    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = Self.nowMilliseconds()
        mutationServerT = snapshot.appliedServerT
        cursorAdvancedAfterMutation = false
        let uuid = UUID().uuidString.lowercased()
        do {
            let payloadData = try JSONEncoder().encode(SendBlockPayload(text: trimmed, uuid: uuid, now: now))
            guard let payload = String(data: payloadData, encoding: .utf8) else {
                lastError = LogseqChatCoreError(code: "request_encoding", message: "Could not encode send payload")
                logger.error("Core request encoding failed: send payload was not UTF-8")
                return
            }
            performAsyncThenSyncPending(LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "send", payload: payload)))
        } catch {
            lastError = LogseqChatCoreError(code: "request_encoding", message: "\(error)")
            logger.error("Core request encoding failed: send, message: \(String(describing: error))")
            self.syncPending()
        }
    }

    public func sendTask(_ text: String, status: LogseqTaskStatus) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = Self.nowMilliseconds()
        let uuid = UUID().uuidString.lowercased()
        let statusPayload = TaskStatusPayload(
            uuid: status.uuid, ident: status.ident, title: status.title,
            iconType: status.icon?.type, iconId: status.icon?.id, iconColor: status.icon?.color
        )
        dispatchEncoded("sendTask", SendTaskPayload(text: trimmed, uuid: uuid, now: now, status: statusPayload))
    }

    public func addAsset(
        title: String, assetType: String, assetSize: Int,
        assetChecksum: String, localPath: String
    ) {
        let now = Self.nowMilliseconds()
        let uuid = UUID().uuidString.lowercased()
        dispatchEncoded(
            "addAsset",
            AddAssetPayload(
                uuid: uuid, title: title, now: now, assetType: assetType,
                assetSize: assetSize, assetChecksum: assetChecksum, localPath: localPath
            )
        )
    }

    private func dispatchEncoded<T: Encodable>(_ action: String, _ payloadValue: T) {
        do {
            let payloadData = try JSONEncoder().encode(payloadValue)
            guard let payload = String(data: payloadData, encoding: .utf8) else {
                lastError = LogseqChatCoreError(code: "request_encoding", message: "Could not encode \(action) payload")
                logger.error("Core request encoding failed: \(action) payload was not UTF-8")
                return
            }
            let request = LogseqChatRPCRequest(
                method: "dispatch",
                params: LogseqChatRPCParams(action: action, payload: payload)
            )
            performAsyncThenSyncPending(request)
        } catch {
            lastError = LogseqChatCoreError(code: "request_encoding", message: "\(error)")
            logger.error("Core request encoding failed: \(action)")
        }
    }

    public func syncPending() {
        pendingSyncRequested = true
        guard pendingSyncTask == nil else { return }
        pendingSyncTask = Task { [weak self] in
            await self?.runPendingSyncPump()
            self?.pendingSyncTask = nil
        }
    }

    public func syncPendingForBackground() async {
        syncPending()
        guard let task = pendingSyncTask else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func update(block: LogseqBlock, title: String) {
        update(block: block, title: title, status: block.status)
    }

    public func update(block: LogseqBlock, title: String, status: LogseqTaskStatus?) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let statusPayload = status.map {
            TaskStatusPayload(
                uuid: $0.uuid, ident: $0.ident, title: $0.title,
                iconType: $0.icon?.type, iconId: $0.icon?.id, iconColor: $0.icon?.color
            )
        }
        applyOptimisticUpdate(block: block, title: trimmed, status: status)
        dispatchEncoded(
            "updateBlock",
            UpdateBlockPayload(uuid: block.uuid, title: trimmed, status: statusPayload)
        )
    }

    public func updateStatus(block: LogseqBlock, status: LogseqTaskStatus) {
        let statusPayload = TaskStatusPayload(
            uuid: status.uuid, ident: status.ident, title: status.title,
            iconType: status.icon?.type, iconId: status.icon?.id, iconColor: status.icon?.color
        )
        applyOptimisticUpdate(block: block, title: block.title, status: status)
        dispatchEncoded(
            "updateBlockStatus",
            UpdateBlockStatusPayload(uuid: block.uuid, status: statusPayload)
        )
    }

    public func select(_ block: LogseqBlock) {
        performAsync(LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "select", payload: block.uuid)))
    }

    public func clearSelection() {
        performAsync(LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "clearSelection")))
    }

    public func loadBlockReferences(_ uuid: String) {
        performAsync(LogseqChatRPCRequest(
            method: "dispatch",
            params: LogseqChatRPCParams(action: "loadBlockReferences", payload: uuid)
        ))
    }

    public func loadPageReferences(_ uuid: String) {
        performAsync(LogseqChatRPCRequest(
            method: "dispatch",
            params: LogseqChatRPCParams(action: "loadPageReferences", payload: uuid)
        ))
    }

    public func loadTagObjects(_ uuid: String) {
        performAsync(LogseqChatRPCRequest(
            method: "dispatch",
            params: LogseqChatRPCParams(action: "loadTagObjects", payload: uuid)
        ))
    }

    public func clearRelated() {
        performAsync(LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "clearRelated")))
    }

    @MainActor public func runPendingSyncLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            syncPending()
        }
    }

    private func performAsync(
        _ request: LogseqChatRPCRequest,
        shouldApply: (@MainActor () -> Bool)? = nil,
        afterApply: (@MainActor () -> Void)? = nil
    ) {
        Task {
            await performAsyncAndWait(request, shouldApply: shouldApply)
            afterApply?()
        }
    }

    private func performAsyncThenSyncPending(_ request: LogseqChatRPCRequest) {
        Task {
            await performAsyncAndWait(request)
            syncPending()
        }
    }

    private func runPendingSyncPump() async {
        repeat {
            pendingSyncRequested = false
            await performAsyncAndWait(
                LogseqChatRPCRequest(
                    method: "dispatch",
                    params: LogseqChatRPCParams(action: "beginPendingSync")
                )
            )
            var pending = snapshot.pendingSyncRequest
            while let request = pending, !Task.isCancelled {
                let result = await pendingTransport(request)
                if Task.isCancelled { break }
                let completion = LogseqPendingSyncCompletion(
                    id: request.id,
                    status: result.status,
                    body: result.body,
                    error: result.error
                )
                await dispatchEncodedAndWait("completePendingSync", completion)
                pending = snapshot.pendingSyncRequest
            }
            if Task.isCancelled {
                await dispatchRawAndWait("cancelPendingSync")
            }
        } while pendingSyncRequested && !Task.isCancelled
    }

    private func performAsyncAndWait(
        _ request: LogseqChatRPCRequest,
        shouldApply: (@MainActor () -> Bool)? = nil
    ) async {
        let actionName = request.params.action ?? request.method
        guard let requestJSON = encode(request) else {
            return
        }
        #if DEBUG
        print("LogseqChat debug: async core action started \(actionName)")
        #endif
        logger.info("Core action started: \(actionName)")
        #if !SKIP
        let responseJSON = await LogseqChatCoreExecutor.shared.call(
            callCore,
            requestJSON: requestJSON
        )
        #else
        let responseJSON = await Self.callInBackground(callCore, requestJSON: requestJSON, actionName: actionName)
        #endif
        #if DEBUG
        print("LogseqChat debug: async core action returned \(actionName)")
        #endif
        logger.info("Core action returned: \(actionName)")
        if shouldApply?() ?? true {
            apply(responseJSON: responseJSON, actionName: actionName)
        }
    }

    nonisolated private static func callInBackground(
        _ callCore: @escaping @Sendable (String) -> String,
        requestJSON: String,
        actionName: String
    ) async -> String {
        #if !SKIP
        await Task.detached(priority: .utility) {
            callCore(requestJSON)
        }.value
        #else
        return await withContext(Dispatchers.IO) {
            callCore(requestJSON)
        }
        #endif
    }

    private func encode(_ request: LogseqChatRPCRequest) -> String? {
        do {
            let requestData = try JSONEncoder().encode(request)
            guard let requestJSON = String(data: requestData, encoding: .utf8) else {
                lastError = LogseqChatCoreError(code: "request_encoding", message: "Could not encode request")
                logger.error("Core request encoding failed: request was not UTF-8")
                return nil
            }
            return requestJSON
        } catch {
            lastError = LogseqChatCoreError(code: "request_encoding", message: "\(error)")
            logger.error("Core request encoding failed: message: \(String(describing: error))")
            return nil
        }
    }

    private func apply(responseJSON: String, actionName: String = "sync") {
        do {
            let responseData = Data(responseJSON.utf8)
            let response = try JSONDecoder().decode(LogseqChatRPCResponse.self, from: responseData)
            if response.ok, let result = response.result {
                let mergedResult = mergedSnapshot(result, actionName: actionName)
                #if DEBUG
                print(
                    "LogseqChat debug: core action applied \(actionName) "
                        + "revision=\(mergedResult.revision) blocks=\(mergedResult.blocks.count) "
                        + "journals=\(mergedResult.blocks.filter { $0.journalDay != nil }.count) "
                        + "graphs=\(mergedResult.graphs?.count ?? 0)"
                )
                #endif
                logger.info(
                    "Core action applied: \(actionName), revision: \(mergedResult.revision), blocks: \(mergedResult.blocks.count), graph: \(mergedResult.graphName ?? "none")"
                )
                snapshot = mergedResult
                lastError = nil
            } else {
                let error = response.error ?? LogseqChatCoreError(code: "unknown_core_error", message: "The core returned no snapshot")
                #if DEBUG
                print(
                    "LogseqChat debug: core action failed \(actionName) "
                        + "code=\(error.code) message=\(error.message)"
                )
                #endif
                logger.error(
                    "Core action failed: \(actionName), code: \(error.code), message: \(error.message)"
                )
                lastError = error
            }
        } catch {
            let coreError = LogseqChatCoreError(code: "response_decoding", message: "\(error)")
            logger.error(
                "Core response decoding failed: \(actionName), message: \(coreError.message)"
            )
            lastError = coreError
        }
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func normalizedBaseURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "https://staging-api.logseq.io" {
            return "https://api-staging.logseq.io"
        }
        if trimmed == "http://staging-api.logseq.io" {
            return "https://api-staging.logseq.io"
        }
        return trimmed
    }

    private func applyOptimisticUpdate(
        block: LogseqBlock, title: String, status: LogseqTaskStatus?
    ) {
        let now = Self.nowMilliseconds()
        let updatedBlock = LogseqBlock(
            uuid: block.uuid,
            kind: status == nil ? block.kind : "task",
            title: title,
            pageId: block.pageId,
            parentId: block.parentId,
            order: block.order,
            createdAt: block.createdAt,
            updatedAt: now,
            syncStatus: block.syncStatus,
            journalTitle: block.journalTitle,
            journalDay: block.journalDay,
            tags: block.tags,
            references: block.references,
            status: status,
            assetType: block.assetType,
            assetSize: block.assetSize,
            assetChecksum: block.assetChecksum,
            localPath: block.localPath
        )
        snapshot = LogseqChatSnapshot(
            revision: snapshot.revision + 1,
            query: snapshot.query,
            blocks: snapshot.blocks.map { $0.uuid == block.uuid ? updatedBlock : $0 },
            selectedBlock: snapshot.selectedBlock,
            lastRefreshAt: snapshot.lastRefreshAt,
            graphName: snapshot.graphName,
            isSearching: snapshot.isSearching,
            selectedGraphId: snapshot.selectedGraphId,
            graphs: snapshot.graphs,
            appliedServerT: snapshot.appliedServerT,
            syncConnected: snapshot.syncConnected,
            relatedBlocks: snapshot.relatedBlocks,
            taskStatuses: snapshot.taskStatuses,
            isGraphEncrypted: snapshot.isGraphEncrypted,
            isGraphUnlocked: snapshot.isGraphUnlocked,
            pendingSyncRequest: snapshot.pendingSyncRequest
        )
        lastError = nil
    }

    private static func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    private func mergedSnapshot(_ result: LogseqChatSnapshot, actionName: String) -> LogseqChatSnapshot {
        let preservesCurrentSearch = actionName != "search" && actionName != "searchLocal" && snapshot.isSearching
        let query = preservesCurrentSearch ? snapshot.query : result.query
        let isSearching = preservesCurrentSearch ? snapshot.isSearching : result.isSearching
        if let mutationServerT, let appliedServerT = result.appliedServerT,
           appliedServerT > mutationServerT {
            cursorAdvancedAfterMutation = true
            self.mutationServerT = nil
        }
        return LogseqChatSnapshot(
            revision: result.revision,
            query: query,
            blocks: mergedBlocks(from: result.blocks, query: query),
            selectedBlock: result.selectedBlock,
            lastRefreshAt: result.lastRefreshAt,
            graphName: result.graphName,
            isSearching: isSearching,
            selectedGraphId: result.selectedGraphId,
            graphs: result.graphs ?? snapshot.graphs,
            appliedServerT: result.appliedServerT,
            syncConnected: result.syncConnected,
            relatedBlocks: result.relatedBlocks,
            taskStatuses: result.taskStatuses ?? snapshot.taskStatuses,
            isGraphEncrypted: result.isGraphEncrypted,
            isGraphUnlocked: result.isGraphUnlocked,
            pendingSyncRequest: result.pendingSyncRequest
        )
    }

    private func mergedBlocks(from blocks: [LogseqBlock], query: String) -> [LogseqBlock] {
        blocks.filter { Self.block($0, matches: query) }
    }

    private static func block(_ block: LogseqBlock, matches query: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else {
            return true
        }
        if block.title.lowercased().contains(normalizedQuery) {
            return true
        }
        if block.pageId.lowercased().contains(normalizedQuery) {
            return true
        }
        if block.uuid.lowercased().contains(normalizedQuery) {
            return true
        }
        return block.parentId?.lowercased().contains(normalizedQuery) == true
    }
}
