import Foundation
import Observation
import OSLog
#if SKIP
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
#endif
import SkipFFI
#if !SKIP
import LogseqChatCoreABI
#endif

let logger: Logger = Logger(subsystem: "logseq.chat.model", category: "LogseqChatModel")

public final class LogseqChatCore {
    nonisolated(unsafe) public static let shared = registerNatives(
        LogseqChatCore(),
        frameworkName: "LogseqChat",
        libraryName: "logseq_chat_core"
    )

    private init() {
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
        case uuid, kind, title, pageId, parentId, createdAt, updatedAt, syncStatus
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

public struct LogseqChatSnapshot: Codable {
    public let revision: Int
    public let query: String
    public let blocks: [LogseqBlock]
    public let selectedBlock: LogseqBlock?
    public let lastRefreshAt: Int64?
    public let graphName: String?
    public let isSearching: Bool
    public let relatedBlocks: [LogseqBlock]?
    public let taskStatuses: [LogseqTaskStatus]?

    public init(
        revision: Int, query: String, blocks: [LogseqBlock], selectedBlock: LogseqBlock?,
        lastRefreshAt: Int64?, graphName: String?, isSearching: Bool,
        relatedBlocks: [LogseqBlock]? = nil,
        taskStatuses: [LogseqTaskStatus]? = nil
    ) {
        self.revision = revision
        self.query = query
        self.blocks = blocks
        self.selectedBlock = selectedBlock
        self.lastRefreshAt = lastRefreshAt
        self.graphName = graphName
        self.isSearching = isSearching
        self.relatedBlocks = relatedBlocks
        self.taskStatuses = taskStatuses
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

    private let callCore: @Sendable (String) -> String
    private var searchGeneration = 0
    private var optimisticBlocks: [String: LogseqBlock] = [:]

    public init(call: @escaping @Sendable (String) -> String) {
        self.callCore = call
    }

    public var sections: [LogseqBlockSection] {
        let newestFirstBlocks = snapshot.blocks.sorted { left, right in
            if left.createdAt == right.createdAt {
                return left.uuid < right.uuid
            }
            return left.createdAt > right.createdAt
        }
        var blocksByJournal: [String: [LogseqBlock]] = [:]
        var titlesByJournal: [String: String] = [:]
        for block in newestFirstBlocks {
            blocksByJournal[block.journalSectionID, default: []].append(block)
            titlesByJournal[block.journalSectionID] = block.dayTitle
        }
        return blocksByJournal.map { id, blocks in
            let oldestFirstBlocks = blocks.sorted { left, right in
                if left.createdAt == right.createdAt {
                    return left.uuid < right.uuid
                }
                return left.createdAt < right.createdAt
            }
            return LogseqBlockSection(id: id, title: titlesByJournal[id] ?? id, blocks: oldestFirstBlocks)
        }.sorted { left, right in
            let leftCreatedAt = left.blocks.isEmpty ? 0 : left.blocks[left.blocks.count - 1].createdAt
            let rightCreatedAt = right.blocks.isEmpty ? 0 : right.blocks[right.blocks.count - 1].createdAt
            if leftCreatedAt == rightCreatedAt {
                return left.id < right.id
            }
            return leftCreatedAt < rightCreatedAt
        }
    }

    public func open(path: String) {
        perform(LogseqChatRPCRequest(method: "open", params: LogseqChatRPCParams(action: nil, path: path)))
    }

    public func configure(baseURL: String, token: String, refreshAfterApply: Bool = true) {
        let baseURL = Self.normalizedBaseURL(baseURL)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = """
        {"baseUrl":"\(Self.escape(baseURL))","token":"\(Self.escape(token))"}
        """
        performAsync(LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "configure", payload: payload)), afterApply: {
            if refreshAfterApply {
                self.refreshSoon()
            }
        })
    }

    public func configureAndRefreshForBackground(baseURL: String, token: String) async {
        let baseURL = Self.normalizedBaseURL(baseURL)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = """
        {"baseUrl":"\(Self.escape(baseURL))","token":"\(Self.escape(token))"}
        """
        await performAsyncAndWait(
            LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "configure", payload: payload))
        )
        await refreshAndSyncForBackground()
    }

    public func refresh() {
        refresh(afterApply: nil)
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
        let uuid = UUID().uuidString.lowercased()
        applyOptimisticSend(title: trimmed, uuid: uuid, now: now)
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
            logger.error("Core request encoding failed: send, message: \(String(describing: error), privacy: .public)")
            self.syncPending()
        }
    }

    public func sendTask(_ text: String, status: LogseqTaskStatus) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = Self.nowMilliseconds()
        let uuid = UUID().uuidString.lowercased()
        applyOptimisticBlock(title: trimmed, uuid: uuid, kind: "task", now: now, status: status)
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
        applyOptimisticBlock(
            title: title, uuid: uuid, kind: "asset", now: now,
            assetType: assetType, assetSize: assetSize,
            assetChecksum: assetChecksum, localPath: localPath
        )
        dispatchEncoded(
            "addAsset",
            AddAssetPayload(
                uuid: uuid, title: title, now: now, assetType: assetType,
                assetSize: assetSize, assetChecksum: assetChecksum, localPath: localPath
            )
        )
    }

    private func dispatchEncoded<T: Encodable>(
        _ action: String, _ payloadValue: T, syncPendingAfter: Bool = true
    ) {
        do {
            let payloadData = try JSONEncoder().encode(payloadValue)
            guard let payload = String(data: payloadData, encoding: .utf8) else {
                lastError = LogseqChatCoreError(code: "request_encoding", message: "Could not encode \(action) payload")
                logger.error("Core request encoding failed: \(action, privacy: .public) payload was not UTF-8")
                return
            }
            let request = LogseqChatRPCRequest(
                method: "dispatch",
                params: LogseqChatRPCParams(action: action, payload: payload)
            )
            if syncPendingAfter {
                performAsyncThenSyncPending(request)
            } else {
                performAsync(request)
            }
        } catch {
            lastError = LogseqChatCoreError(code: "request_encoding", message: "\(error)")
            logger.error("Core request encoding failed: \(action, privacy: .public)")
        }
    }

    public func syncPending() {
        performAsync(LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "syncPending")))
    }

    public func refreshAndSyncForBackground() async {
        isRefreshing = true
        await performAsyncAndWait(LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "refresh")))
        isRefreshing = false
        if lastError == nil {
            await performAsyncAndWait(LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "syncPending")))
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
            UpdateBlockPayload(uuid: block.uuid, title: trimmed, status: statusPayload),
            syncPendingAfter: false
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
            UpdateBlockStatusPayload(uuid: block.uuid, status: statusPayload),
            syncPendingAfter: false
        )
    }

    public func select(_ block: LogseqBlock) {
        perform(LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "select", payload: block.uuid)))
    }

    public func clearSelection() {
        perform(LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "clearSelection")))
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

    @MainActor public func runRefreshLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            refresh()
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
            await performAsyncAndWait(LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "syncPending")))
        }
    }

    private func perform(
        _ request: LogseqChatRPCRequest,
        shouldApply: (@MainActor () -> Bool)? = nil
    ) {
        let actionName = request.params.action ?? request.method
        guard let requestJSON = encode(request) else {
            return
        }
        logger.info("Core action started: \(actionName, privacy: .public)")
        let responseJSON = callCore(requestJSON)
        logger.info("Core action returned: \(actionName, privacy: .public)")
        if shouldApply?() ?? true {
            apply(responseJSON: responseJSON, actionName: actionName)
        }
    }

    private func performAsyncAndWait(
        _ request: LogseqChatRPCRequest,
        shouldApply: (@MainActor () -> Bool)? = nil
    ) async {
        let actionName = request.params.action ?? request.method
        guard let requestJSON = encode(request) else {
            return
        }
        let callCore = callCore
        logger.info("Core action started: \(actionName, privacy: .public)")
        let responseJSON = await Self.callInBackground(callCore, requestJSON: requestJSON, actionName: actionName)
        logger.info("Core action returned: \(actionName, privacy: .public)")
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
            logger.error("Core request encoding failed: message: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func apply(responseJSON: String, actionName: String = "sync") {
        do {
            let responseData = Data(responseJSON.utf8)
            let response = try JSONDecoder().decode(LogseqChatRPCResponse.self, from: responseData)
            if response.ok, let result = response.result {
                let mergedResult = mergedSnapshot(result, actionName: actionName)
                logger.info(
                    "Core action applied: \(actionName, privacy: .public), revision: \(mergedResult.revision, privacy: .public), blocks: \(mergedResult.blocks.count, privacy: .public), graph: \(mergedResult.graphName ?? "none", privacy: .public)"
                )
                snapshot = mergedResult
                lastError = nil
            } else {
                let error = response.error ?? LogseqChatCoreError(code: "unknown_core_error", message: "The core returned no snapshot")
                logger.error(
                    "Core action failed: \(actionName, privacy: .public), code: \(error.code, privacy: .public), message: \(error.message, privacy: .public)"
                )
                lastError = error
            }
        } catch {
            let coreError = LogseqChatCoreError(code: "response_decoding", message: "\(error)")
            logger.error(
                "Core response decoding failed: \(actionName, privacy: .public), message: \(coreError.message, privacy: .public)"
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

    private func applyOptimisticSend(title: String, uuid: String, now: Int64) {
        applyOptimisticBlock(title: title, uuid: uuid, kind: "block", now: now)
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
            relatedBlocks: snapshot.relatedBlocks,
            taskStatuses: snapshot.taskStatuses
        )
        lastError = nil
    }

    private func applyOptimisticBlock(
        title: String, uuid: String, kind: String, now: Int64,
        status: LogseqTaskStatus? = nil, assetType: String? = nil,
        assetSize: Int? = nil, assetChecksum: String? = nil, localPath: String? = nil
    ) {
        let block = LogseqBlock(
            uuid: uuid,
            kind: kind,
            title: title,
            pageId: Self.journalPageId(for: Date(timeIntervalSince1970: Double(now) / 1000.0)),
            parentId: nil,
            createdAt: now,
            updatedAt: now,
            syncStatus: "pending",
            journalTitle: Self.dayTitle(for: Date(timeIntervalSince1970: Double(now) / 1000.0)),
            journalDay: Self.journalDay(for: Date(timeIntervalSince1970: Double(now) / 1000.0)),
            status: status, assetType: assetType, assetSize: assetSize,
            assetChecksum: assetChecksum, localPath: localPath
        )
        optimisticBlocks[uuid] = block
        snapshot = LogseqChatSnapshot(
            revision: snapshot.revision + 1,
            query: snapshot.query,
            blocks: mergedBlocks(from: snapshot.blocks, query: snapshot.query),
            selectedBlock: snapshot.selectedBlock,
            lastRefreshAt: now,
            graphName: snapshot.graphName,
            isSearching: snapshot.isSearching,
            relatedBlocks: snapshot.relatedBlocks,
            taskStatuses: snapshot.taskStatuses
        )
        lastError = nil
    }

    private static func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    private static func journalPageId(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return "journal/\(pad(year, to: 4))-\(pad(month, to: 2))-\(pad(day, to: 2))"
    }

    private static func journalDay(for date: Date) -> Int {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return (components.year ?? 0) * 10_000 + (components.month ?? 0) * 100 + (components.day ?? 0)
    }

    private static func dayTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private static func pad(_ value: Int, to width: Int) -> String {
        let string = "\(value)"
        if string.count >= width {
            return string
        }
        return String(repeating: "0", count: width - string.count) + string
    }

    private func mergedSnapshot(_ result: LogseqChatSnapshot, actionName: String) -> LogseqChatSnapshot {
        for uuid in result.blocks.map(\.uuid) {
            optimisticBlocks.removeValue(forKey: uuid)
        }

        let preservesCurrentSearch = actionName != "search" && actionName != "searchLocal" && snapshot.isSearching
        let query = preservesCurrentSearch ? snapshot.query : result.query
        let isSearching = preservesCurrentSearch ? snapshot.isSearching : result.isSearching
        return LogseqChatSnapshot(
            revision: result.revision,
            query: query,
            blocks: mergedBlocks(from: result.blocks, query: query),
            selectedBlock: result.selectedBlock,
            lastRefreshAt: result.lastRefreshAt,
            graphName: result.graphName,
            isSearching: isSearching,
            relatedBlocks: result.relatedBlocks,
            taskStatuses: result.taskStatuses ?? snapshot.taskStatuses
        )
    }

    private func mergedBlocks(from blocks: [LogseqBlock], query: String) -> [LogseqBlock] {
        let knownUUIDs = Set(blocks.map(\.uuid))
        let visibleBlocks = blocks.filter { Self.block($0, matches: query) }
        let pendingBlocks = optimisticBlocks.values
            .filter { !knownUUIDs.contains($0.uuid) }
            .filter { Self.block($0, matches: query) }
            .sorted { left, right in
                if left.createdAt == right.createdAt {
                    return left.uuid < right.uuid
                }
                return left.createdAt > right.createdAt
            }
        return pendingBlocks + visibleBlocks
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
