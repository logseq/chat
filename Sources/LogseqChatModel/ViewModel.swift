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

private struct LogseqPendingSyncCompletion: Encodable {
    let id: Int
    let status: Int?
    let body: String?
    let error: String?
}

private struct ConfigurePayload: Encodable {
    let baseUrl: String
    let graphId: String
    let token: String
}

private struct UpdateBlockPayload: Encodable {
    let uuid: String
    let operationId: String
    let expectedTitle: String
    let title: String
    let status: TaskStatusPayload?
}

private struct UpdateBlockStatusPayload: Encodable {
    let uuid: String
    let operationId: String
    let expectedStatusUuid: String?
    let expectedStatusIdent: String?
    let status: TaskStatusPayload
}

private struct DeleteBlockPayload: Encodable {
    let uuid: String
    let operationId: String
    let expectedServerT: Int
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
    let targetBlockId: String?
}

private struct AddChildBlockPayload: Encodable {
    let uuid: String
    let title: String
    let parentId: String
    let now: Int64
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

private struct CreateSyncGraphPayload: Encodable {
    let name: String
    let isEncrypted: Bool
}

private struct ReviewFlashcardPayload: Encodable {
    let uuid: String
    let rating: String
    let now: Int64
    let operationId: String
}

@MainActor @Observable public final class LogseqChatStore {
    public private(set) var snapshot = LogseqChatSnapshot(
        revision: 0,
        blocks: [],
        selectedBlock: nil,
        lastRefreshAt: nil,
        graphName: nil,
        relatedBlocks: nil
    )
    public private(set) var lastError: LogseqChatCoreError?
    public private(set) var isRefreshing = false
    public private(set) var cursorAdvancedAfterMutation = false
    public private(set) var captureRequestRevision = 0
    public private(set) var isSnapshotRefreshDeferred = false

    private let callCore: @Sendable (String) -> String
    private let pendingTransport: @Sendable (LogseqPendingSyncRequest) async -> LogseqPendingSyncResult
    private var searchGeneration = 0
    private var openedDatabasePath: String?
    private var activeGraphID: String?
    private var debugDatabaseRoute = "unopened"
    private var mutationServerT: Int?
    private var pendingSyncTask: Task<Void, Never>?
    private var pendingSyncDebounceTask: Task<Void, Never>?
    private var pendingSyncRequested = false
    private var outlinerEventTask: Task<Void, Never>?
    private var outlinerProjectionGeneration = 0
    private var pendingOutlinerTransientEvent: LogseqOutlinerEvent?
    private var outlinerTransientFlushTask: Task<Void, Never>?
    private var outlinerAutosaveTask: Task<Void, Never>?

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
        makeSections(from: snapshot.blocks)
    }

    private func makeSections(from blocks: [LogseqBlock]) -> [LogseqBlockSection] {
        let visibleBlocks = snapshot.selectedPage != nil
            ? blocks
            : blocks.filter { $0.journalDay != nil }
        if let selectedPage = snapshot.selectedPage {
            return [LogseqBlockSection(
                id: selectedPage.uuid,
                title: selectedPage.title,
                blocks: Self.outlinerPreorder(visibleBlocks, pageId: selectedPage.uuid)
            )]
        }
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

    public func sections(for contentMode: LogseqContentMode) -> [LogseqBlockSection] {
        #if DEBUG
        let startedAt = Date()
        #endif
        guard contentMode == .outliner else { return sections }
        let projectedBlocks = snapshot.outlinerRows.isEmpty && !snapshot.blocks.isEmpty
            ? snapshot.blocks
            : snapshot.outlinerRows.map(\.block)
        let result = Array(makeSections(from: projectedBlocks).reversed())
        #if DEBUG
        let milliseconds = Date().timeIntervalSince(startedAt) * 1_000
        logger.info(
            "Section timing: mode=\(contentMode.rawValue), ms=\(String(format: "%.2f", milliseconds)), "
                + "blocks=\(projectedBlocks.count), sections=\(result.count)"
        )
        #endif
        return result
    }

    public func sections(for projection: LogseqNodeProjection) -> [LogseqBlockSection] {
        [LogseqBlockSection(
            id: projection.page.uuid,
            title: projection.page.title,
            blocks: Self.outlinerPreorder(projection.blocks, pageId: projection.page.uuid)
        )]
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
        activeGraphID = nil
        debugDatabaseRoute = "catalog:\(path)"
        #if DEBUG
        print("LOGSEQ_DB_ROUTE request=open route=\(debugDatabaseRoute)")
        logger.info("LOGSEQ_DB_ROUTE request=open route=\(debugDatabaseRoute)")
        #endif
        performAsync(LogseqChatRPCRequest(method: "open", params: LogseqChatRPCParams(action: nil, path: path)))
    }

    public func openAndWait(path: String) async {
        openedDatabasePath = path
        activeGraphID = nil
        debugDatabaseRoute = "catalog:\(path)"
        #if DEBUG
        print("LOGSEQ_DB_ROUTE request=open_and_wait route=\(debugDatabaseRoute)")
        logger.info("LOGSEQ_DB_ROUTE request=open_and_wait route=\(debugDatabaseRoute)")
        #endif
        await performAsyncAndWait(
            LogseqChatRPCRequest(
                method: "open",
                params: LogseqChatRPCParams(action: nil, path: path)
            )
        )
    }

    public nonisolated static func callForLaunch(_ request: LogseqChatRPCRequest) async -> String {
        guard let data = try? JSONEncoder().encode(request),
              let requestJSON = String(data: data, encoding: .utf8) else {
            return ""
        }
        #if !SKIP
        return await LogseqChatCoreExecutor.shared.call(
            { request in LogseqChatCore.shared.logseq_chat_call(request) },
            requestJSON: requestJSON,
            priority: .interaction
        )
        #else
        return LogseqChatCore.shared.logseq_chat_call(requestJSON)
        #endif
    }

    public func applyLaunchResponse(
        _ responseJSON: String,
        actionName: String,
        databasePath: String
    ) {
        let startedAt = Date()
        openedDatabasePath = databasePath
        apply(responseJSON: responseJSON, actionName: actionName)
        if actionName == "openGraph", let graphID = snapshot.selectedGraphId {
            activeGraphID = graphID
            debugDatabaseRoute = "graph:\(graphID)"
            #if DEBUG
            print("LOGSEQ_DB_ROUTE launch_applied route=\(debugDatabaseRoute)")
            #endif
        }
        let elapsedMilliseconds = Date().timeIntervalSince(startedAt) * 1_000
        print(
            "LOGSEQ_LAUNCH_APPLY_METRIC action=\(actionName) "
                + "bytes=\(responseJSON.utf8.count) "
                + "elapsed_ms=\(String(format: "%.3f", elapsedMilliseconds))"
        )
    }

    public func resetToCatalog() async {
        guard let openedDatabasePath else {
            lastError = LogseqChatCoreError(
                code: "database_not_open",
                message: "Open local storage before resetting the graph"
            )
            return
        }
        await performAsyncAndWait(
            LogseqChatRPCRequest(
                method: "open",
                params: LogseqChatRPCParams(action: nil, path: openedDatabasePath)
            )
        )
    }

    public func configure(
        baseURL: String, token: String, graphID: String? = nil,
        refreshAfterApply: Bool = true
    ) {
        let baseURL = Self.normalizedBaseURL(baseURL)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payload = encodePayload(
            ConfigurePayload(baseUrl: baseURL, graphId: graphID ?? "", token: token),
            action: "configure"
        ) else { return }
        performAsync(LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "configure", payload: payload)), afterApply: {
            if refreshAfterApply {
                self.refreshSoon()
            }
        })
    }

    public func configureAndSelectGraph(
        baseURL: String, token: String, selectedGraphID: String?,
        refreshGraphCatalog: Bool = false
    ) async {
        let baseURL = Self.normalizedBaseURL(baseURL)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payload = encodePayload(
            ConfigurePayload(
                baseUrl: baseURL,
                graphId: selectedGraphID ?? "",
                token: token
            ),
            action: "configure"
        ) else { return }
        await performAsyncAndWait(
            LogseqChatRPCRequest(
                method: "dispatch",
                params: LogseqChatRPCParams(action: "configure", payload: payload)
            )
        )
        guard lastError == nil else { return }
        if let selectedGraphID {
            if refreshGraphCatalog && !token.isEmpty {
                await performAsyncAndWait(
                    LogseqChatRPCRequest(
                        method: "dispatch",
                        params: LogseqChatRPCParams(action: "refreshGraphCatalog")
                    )
                )
                guard
                    lastError == nil,
                    snapshot.graphs?.contains(where: { $0.id == selectedGraphID }) == true
                else { return }
            }
            if !token.isEmpty {
                syncPending()
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

    public func createSyncGraph(name: String, isEncrypted: Bool) async -> Bool {
        guard let payload = encodePayload(
            CreateSyncGraphPayload(name: name, isEncrypted: isEncrypted),
            action: "createSyncGraph"
        ) else { return false }
        await dispatchRawAndWait("createSyncGraph", payload: payload)
        return lastError == nil
    }

    public func selectPage(_ pageID: String) {
        performAsync(
            LogseqChatRPCRequest(
                method: "dispatch",
                params: LogseqChatRPCParams(action: "selectPage", payload: pageID)
            ),
            afterApply: nil
        )
    }

    public func openNode(_ nodeID: String) {
        dispatchEncoded("openNode", LogseqNodeRouteRequest(uuid: nodeID))
    }

    /// Opens a node route and reports whether the core resolved it, so the
    /// caller can undo optimistic navigation instead of spinning forever.
    public func openNode(_ nodeID: String, onResolved: @escaping (Bool) -> Void) {
        do {
            let payloadData = try JSONEncoder().encode(LogseqNodeRouteRequest(uuid: nodeID))
            guard let payload = String(data: payloadData, encoding: .utf8) else {
                lastError = LogseqChatCoreError(
                    code: "request_encoding", message: "Could not encode openNode payload"
                )
                onResolved(false)
                return
            }
            performAsync(
                LogseqChatRPCRequest(
                    method: "dispatch",
                    params: LogseqChatRPCParams(action: "openNode", payload: payload)
                ),
                afterApply: {
                    onResolved(self.snapshot.nodeRoutes.contains { $0.uuid == nodeID })
                }
            )
        } catch {
            lastError = LogseqChatCoreError(code: "request_encoding", message: "\(error)")
            onResolved(false)
        }
    }

    public func closeNode() {
        performAsync(LogseqChatRPCRequest(
            method: "dispatch",
            params: LogseqChatRPCParams(action: "closeNode")
        ))
    }

    public func clearSelectedPage() {
        performAsync(
            LogseqChatRPCRequest(
                method: "dispatch",
                params: LogseqChatRPCParams(action: "clearSelectedPage")
            ),
            afterApply: nil
        )
    }

    public func requestCapture() {
        clearSelectedPage()
        captureRequestRevision += 1
    }

    public func loadOlderJournals() {
        performAsync(
            LogseqChatRPCRequest(
                method: "dispatch",
                params: LogseqChatRPCParams(action: "loadOlderJournals")
            ),
            afterApply: nil
        )
    }

    public func loadFlashcards(now: Int64? = nil) {
        performAsync(
            LogseqChatRPCRequest(
                method: "dispatch",
                params: LogseqChatRPCParams(
                    action: "loadFlashcards",
                    payload: String(now ?? Self.nowMilliseconds())
                )
            ),
            afterApply: nil
        )
    }

    public func reviewFlashcard(
        uuid: String,
        rating: String,
        now: Int64? = nil,
        operationID: String? = nil
    ) {
        dispatchEncoded(
            "reviewFlashcard",
            ReviewFlashcardPayload(
                uuid: uuid,
                rating: rating,
                now: now ?? Self.nowMilliseconds(),
                operationId: operationID ?? UUID().uuidString.lowercased()
            )
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
        if forceSnapshot {
            isSnapshotRefreshDeferred = true
        }
        if !forceSnapshot,
           activeGraphID == graphID,
           snapshot.selectedGraphId == graphID,
           snapshot.appliedServerT != nil {
            #if DEBUG
            print("LOGSEQ_DB_ROUTE bootstrap_early_return graph=\(graphID) route=\(debugDatabaseRoute)")
            logger.info(
                "LOGSEQ_DB_ROUTE bootstrap_early_return graph=\(graphID) "
                    + "route=\(debugDatabaseRoute)"
            )
            #endif
            return true
        }
        do {
            let graphDirectory = LogseqGraphLocalStorage.directoryURL(
                databasePath: openedDatabasePath,
                graphID: graphID
            )
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
                    activeGraphID = graphID
                    debugDatabaseRoute = "graph:\(graphID)"
                    isSnapshotRefreshDeferred = false
                    #if DEBUG
                    print("LOGSEQ_DB_ROUTE open_graph_applied route=\(debugDatabaseRoute)")
                    #endif
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
                baseURL: baseURL,
                graphID: graphID,
                accessToken: accessToken
            )
            #endif
            defer { try? FileManager.default.removeItem(atPath: artifact.filePath) }
            let isEditingOutlinerBlock = snapshot.outlinerState.editing != nil
                || snapshot.nodeRoutes.last?.outlinerState.editing != nil
            guard LogseqGraphSnapshotRefreshPolicy.shouldApplyDownloadedSnapshot(
                forceSnapshot: forceSnapshot,
                isEditingOutlinerBlock: isEditingOutlinerBlock,
                hasPendingLocalChanges: snapshot.hasPendingSemanticOperations
                    || snapshot.pendingSyncRequest != nil
            ) else {
                isSnapshotRefreshDeferred = true
                return true
            }
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
            if lastError == nil {
                activeGraphID = graphID
                debugDatabaseRoute = "graph:\(graphID)"
                isSnapshotRefreshDeferred = forceSnapshot
            }
            return lastError == nil
        } catch {
            isSnapshotRefreshDeferred = false
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
            isSnapshotRefreshDeferred = false
            while let frame = try await stream.nextFrame() {
                await dispatchRawAndWait("feedSSE", payload: frame)
                if lastError != nil { break }
                syncPendingSoon()
                if lastError != nil { break }
                if stopAfterFirstFrame { break }
            }
            let streamError = lastError
            if streamError?.code == "snapshot_required" {
                lastError = nil
            }
            await dispatchRawAndWait("stopSSE")
            if let streamError {
                if streamError.code == "snapshot_required" {
                    return true
                }
                lastError = streamError
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
            isSnapshotRefreshDeferred = false
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
                        syncPendingSoon()
                        if lastError != nil { break }
                        if stopAfterFirstFrame { break eventStream }
                    }
                    if lastError != nil { break }
                }
            }
            let streamError = lastError
            if streamError?.code == "snapshot_required" {
                lastError = nil
            }
            await dispatchRawAndWait("stopSSE")
            if let streamError {
                if streamError.code == "snapshot_required" {
                    return true
                }
                lastError = streamError
            }
        } catch {
            await dispatchRawAndWait("stopSSE")
            if LogseqGraphSSEFailurePolicy.shouldReport(
                error,
                taskIsCancelled: Task.isCancelled
            ) {
                lastError = LogseqChatCoreError(code: "sse_connection_failed", message: "\(error)")
            }
        }
        return false
        #endif
    }

    public func deferSnapshotRefreshWhileEditing() {
        isSnapshotRefreshDeferred = true
        if lastError?.code == "snapshot_required" {
            lastError = nil
        }
    }

    private func dispatchEncodedAndWait<T: Encodable>(
        _ action: String,
        _ value: T,
        shouldApply: (() -> Bool)? = nil
    ) async {
        guard let payload = encodePayload(value, action: action) else { return }
        await performAsyncAndWait(
            LogseqChatRPCRequest(
                method: "dispatch",
                params: LogseqChatRPCParams(action: action, payload: payload)
            ),
            shouldApply: shouldApply
        )
    }

    private func dispatchRawAndWait(_ action: String, payload: String? = nil) async {
        await performAsyncAndWait(
            LogseqChatRPCRequest(
                method: "dispatch",
                params: LogseqChatRPCParams(action: action, payload: payload)
            )
        )
    }

    private func refresh(afterApply: (() -> Void)?) {
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

    public func searchNodes(_ query: String) {
        searchGeneration += 1
        let generation = searchGeneration
        performAsync(
            LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "searchNodes", payload: query)),
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

    public func captureSharedText(_ text: String, id: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        lastError = nil
        mutationServerT = snapshot.appliedServerT
        cursorAdvancedAfterMutation = false
        await dispatchEncodedAndWait(
            "send",
            SendBlockPayload(text: trimmed, uuid: id, now: Self.nowMilliseconds())
        )
        guard lastError == nil else { return false }
        syncPending()
        return true
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

    @discardableResult public func addAsset(
        title: String, assetType: String, assetSize: Int,
        assetChecksum: String, localPath: String, targetBlockId: String? = nil
    ) -> String {
        #if DEBUG
        print(
            "LOGSEQ_DB_ROUTE add_asset route=\(debugDatabaseRoute) "
                + "snapshot_graph=\(snapshot.selectedGraphId ?? "none") path=\(localPath)"
        )
        logger.info(
            "LOGSEQ_DB_ROUTE add_asset route=\(debugDatabaseRoute) "
                + "snapshot_graph=\(snapshot.selectedGraphId ?? "none")"
        )
        #endif
        let now = Self.nowMilliseconds()
        let uuid = UUID().uuidString.lowercased()
        dispatchEncoded(
            "addAsset",
            AddAssetPayload(
                uuid: uuid, title: title, now: now, assetType: assetType,
                assetSize: assetSize, assetChecksum: assetChecksum, localPath: localPath,
                targetBlockId: targetBlockId
            )
        )
        return uuid
    }

    public func captureSharedAsset(
        id: String,
        title: String,
        assetType: String,
        assetSize: Int,
        assetChecksum: String,
        localPath: String
    ) async -> Bool {
        lastError = nil
        await dispatchEncodedAndWait(
            "addAsset",
            AddAssetPayload(
                uuid: id,
                title: title,
                now: Self.nowMilliseconds(),
                assetType: assetType,
                assetSize: assetSize,
                assetChecksum: assetChecksum,
                localPath: localPath,
                targetBlockId: nil
            )
        )
        guard lastError == nil else { return false }
        syncPending()
        return true
    }

    @discardableResult public func addChildBlock(_ title: String, parentId: String) -> String {
        let uuid = UUID().uuidString.lowercased()
        dispatchEncoded(
            "addChildBlock",
            AddChildBlockPayload(
                uuid: uuid, title: title, parentId: parentId, now: Self.nowMilliseconds()
            )
        )
        return uuid
    }

    private func dispatchEncoded<T: Encodable>(_ action: String, _ payloadValue: T) {
        guard let payload = encodePayload(payloadValue, action: action) else { return }
        let request = LogseqChatRPCRequest(
            method: "dispatch",
            params: LogseqChatRPCParams(action: action, payload: payload)
        )
        performAsyncThenSyncPending(request)
    }

    public func syncPending() {
        pendingSyncDebounceTask?.cancel()
        pendingSyncDebounceTask = nil
        pendingSyncRequested = true
        guard pendingSyncTask == nil else { return }
        pendingSyncTask = Task { [weak self] in
            await self?.runPendingSyncPump()
            guard let self else { return }
            self.pendingSyncTask = nil
            if LogseqPendingSyncPumpPolicy.shouldRestartAfterFinishing(
                requestedWhileFinishing: self.pendingSyncRequested
            ) {
                self.syncPending()
            }
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
        dispatchEncoded(
            "updateBlock",
            UpdateBlockPayload(
                uuid: block.uuid,
                operationId: UUID().uuidString.lowercased(),
                expectedTitle: block.title,
                title: trimmed,
                status: statusPayload
            )
        )
    }

    public func updateStatus(block: LogseqBlock, status: LogseqTaskStatus) {
        let statusPayload = TaskStatusPayload(
            uuid: status.uuid, ident: status.ident, title: status.title,
            iconType: status.icon?.type, iconId: status.icon?.id, iconColor: status.icon?.color
        )
        dispatchEncoded(
            "updateBlockStatus",
            UpdateBlockStatusPayload(
                uuid: block.uuid,
                operationId: UUID().uuidString.lowercased(),
                expectedStatusUuid: block.status?.uuid,
                expectedStatusIdent: block.status?.ident,
                status: statusPayload
            )
        )
    }

    public func delete(block: LogseqBlock) {
        guard let expectedServerT = snapshot.appliedServerT else {
            lastError = LogseqChatCoreError(
                code: "delete_requires_server_cursor",
                message: "Delete requires an authoritative server cursor"
            )
            return
        }
        dispatchEncoded(
            "deleteBlock",
            DeleteBlockPayload(
                uuid: block.uuid,
                operationId: UUID().uuidString.lowercased(),
                expectedServerT: expectedServerT
            )
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

    public func outlinerEvent(_ event: LogseqOutlinerEvent) {
        #if DEBUG
        logger.info(
            "Outliner event queued: type=\(event.type), uuid=\(event.uuid ?? "nil"), "
                + "action=\(event.action ?? "nil")"
        )
        #endif
        if event.type != "textChanged" && event.type != "caretMoved" {
            outlinerAutosaveTask?.cancel()
            outlinerAutosaveTask = nil
        }
        let isAtomicStructureEvent =
            (event.type == "returnPressed" && event.title != nil
                && event.caretUTF16Offset != nil)
            || (event.type == "backspacePressed" && event.title != nil)
        if event.type == "textChanged" || isAtomicStructureEvent {
            outlinerProjectionGeneration += 1
        }
        let generation = outlinerProjectionGeneration
        if isAtomicStructureEvent {
            outlinerTransientFlushTask?.cancel()
            outlinerTransientFlushTask = nil
            pendingOutlinerTransientEvent = nil
            enqueueOutlinerEvent(
                event,
                generation: generation,
                canBeSuperseded: false
            )
            return
        }
        let isTransient = (event.type == "textChanged" || event.type == "caretMoved")
            && !opensAutocompleteImmediately(event)
        if isTransient {
            if event.type == "caretMoved", var pending = pendingOutlinerTransientEvent,
               pending.type == "textChanged" {
                pending.caretUTF16Offset = event.caretUTF16Offset
                pendingOutlinerTransientEvent = pending
            } else {
                pendingOutlinerTransientEvent = event
            }
            outlinerTransientFlushTask?.cancel()
            outlinerTransientFlushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled, let self else { return }
                self.outlinerTransientFlushTask = nil
                guard let pending = self.pendingOutlinerTransientEvent else { return }
                self.pendingOutlinerTransientEvent = nil
                self.enqueueOutlinerEvent(pending, generation: generation, canBeSuperseded: true)
            }
            return
        }

        outlinerTransientFlushTask?.cancel()
        outlinerTransientFlushTask = nil
        if let pending = pendingOutlinerTransientEvent {
            pendingOutlinerTransientEvent = nil
            if event.type == "toolbar" && event.action == "task" {
                enqueueOutlinerEvent(event, generation: generation, canBeSuperseded: false)
                enqueueOutlinerEvent(pending, generation: generation, canBeSuperseded: false)
                return
            }
            enqueueOutlinerEvent(pending, generation: generation, canBeSuperseded: false)
        }
        enqueueOutlinerEvent(event, generation: generation, canBeSuperseded: false)
    }

    private func enqueueOutlinerEvent(
        _ event: LogseqOutlinerEvent,
        generation: Int,
        canBeSuperseded: Bool
    ) {
        let previous = outlinerEventTask
        outlinerEventTask = Task { [weak self] in
            _ = await previous?.value
            guard let self else { return }
            if canBeSuperseded, self.outlinerProjectionGeneration != generation {
                return
            }
            let projectionIsCurrent = self.outlinerProjectionGeneration == generation
            var dispatchedEvent = event
            if event.type == "returnPressed" || event.type == "backspacePressed" {
                let currentEditing = self.snapshot.nodeRoutes.last?.outlinerState.editing
                    ?? self.snapshot.outlinerState.editing
                if let currentEditing, event.uuid != currentEditing.uuid {
                    dispatchedEvent.uuid = currentEditing.uuid
                    dispatchedEvent.title = currentEditing.title
                    if event.type == "returnPressed" {
                        dispatchedEvent.caretUTF16Offset = currentEditing.caretUTF16Offset
                    }
                }
            }
            await self.dispatchEncodedAndWait(
                "outlinerEvent",
                dispatchedEvent,
                shouldApply: {
                    !canBeSuperseded || projectionIsCurrent
                }
            )
            if event.type == "textChanged" {
                let autocomplete = self.snapshot.nodeRoutes.last?.outlinerState.autocomplete
                    ?? self.snapshot.outlinerState.autocomplete
                if autocomplete == nil {
                    self.scheduleOutlinerAutosave()
                } else {
                    self.outlinerAutosaveTask?.cancel()
                    self.outlinerAutosaveTask = nil
                }
            } else if event.type == "chooseAutocomplete" {
                self.scheduleOutlinerAutosave()
            }
            if self.snapshot.hasPendingSemanticOperations {
                self.syncPendingSoon(
                    delayNanoseconds: LogseqOutlinerAutosavePolicy.serverSyncDelayNanoseconds(
                        eventType: event.type
                    )
                )
            }
        }
    }

    private func opensAutocompleteImmediately(_ event: LogseqOutlinerEvent) -> Bool {
        guard event.type == "textChanged", let title = event.title,
              let caret = event.caretUTF16Offset else { return false }
        #if SKIP
        let location = min(max(caret, 0), title.count)
        let prefix = title.substring(0, location)
        #else
        let value = title as NSString
        let location = min(max(caret, 0), value.length)
        let prefix = value.substring(to: location)
        #endif
        return prefix.hasSuffix("#") || prefix.hasSuffix("[[") || prefix.hasSuffix("::")
    }

    private func scheduleOutlinerAutosave() {
        outlinerAutosaveTask?.cancel()
        outlinerAutosaveTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: LogseqOutlinerAutosavePolicy.serverSyncDelayNanoseconds(
                    eventType: "textChanged"
                )
            )
            guard !Task.isCancelled, let self else { return }
            self.outlinerAutosaveTask = nil
            self.outlinerEvent(LogseqOutlinerEvent(type: "saveEditing"))
        }
    }

    private func syncPendingSoon(delayNanoseconds: UInt64 = 150_000_000) {
        pendingSyncDebounceTask?.cancel()
        pendingSyncDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.pendingSyncDebounceTask = nil
            self.syncPending()
        }
    }

    @MainActor public func runPendingSyncLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            syncPending()
        }
    }

    private func performAsync(
        _ request: LogseqChatRPCRequest,
        shouldApply: (() -> Bool)? = nil,
        afterApply: (() -> Void)? = nil
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
        shouldApply: (() -> Bool)? = nil
    ) async {
        let actionName = request.params.action ?? request.method
        guard let requestJSON = encode(request) else {
            return
        }
        #if DEBUG
        print("LogseqChat debug: async core action started \(actionName)")
        let coreStartedAt = Date()
        #endif
        logger.info("Core action started: \(actionName)")
        #if !SKIP
        let responseJSON = await LogseqChatCoreExecutor.shared.call(
            callCore,
            requestJSON: requestJSON,
            priority: Self.corePriority(for: actionName)
        )
        #else
        let responseJSON = await Self.callInBackground(callCore, requestJSON: requestJSON, actionName: actionName)
        #endif
        #if DEBUG
        let coreMilliseconds = Date().timeIntervalSince(coreStartedAt) * 1_000
        let coreTiming =
            "Core timing: action=\(actionName), coreMs=\(String(format: "%.2f", coreMilliseconds)), "
                + "requestBytes=\(requestJSON.utf8.count), responseBytes=\(responseJSON.utf8.count)"
        logger.info(coreTiming)
        print(
            "LogseqChat debug: async core action returned \(actionName) "
                + "coreMs=\(String(format: "%.2f", coreMilliseconds)) "
                + "requestBytes=\(requestJSON.utf8.count) responseBytes=\(responseJSON.utf8.count)"
        )
        if responseJSON.contains("invalid_json") {
            let locallyValid = (try? JSONSerialization.jsonObject(
                with: Data(requestJSON.utf8)
            )) != nil
            print(
                "LogseqChat debug: invalid_json action=\(actionName) "
                    + "bytes=\(requestJSON.utf8.count) locallyValid=\(locallyValid)"
            )
        }
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
        return await AndroidCoreExecutor.call(requestJSON: requestJSON, callCore: callCore)
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

    private func encodePayload<T: Encodable>(_ value: T, action: String) -> String? {
        do {
            let data = try JSONEncoder().encode(value)
            guard let payload = String(data: data, encoding: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            return payload
        } catch {
            lastError = LogseqChatCoreError(code: "request_encoding", message: "\(error)")
            logger.error("Core request encoding failed: \(action)")
            return nil
        }
    }

    private func apply(responseJSON: String, actionName: String = "sync") {
        #if DEBUG
        let applyStartedAt = Date()
        #endif
        do {
            let responseData = Data(responseJSON.utf8)
            let response = try JSONDecoder().decode(LogseqChatRPCResponse.self, from: responseData)
            if response.ok, let result = response.result {
                let mergedResult = mergedSnapshot(result)
                #if DEBUG
                let applyMilliseconds = Date().timeIntervalSince(applyStartedAt) * 1_000
                logger.info(
                    "Apply timing: action=\(actionName), applyMs=\(String(format: "%.2f", applyMilliseconds)), "
                        + "blocks=\(mergedResult.blocks.count), rows=\(mergedResult.outlinerRows.count), "
                        + "patch=\(result.isOutlinerPatch)"
                )
                print(
                    "LogseqChat debug: core action applied \(actionName) "
                        + "revision=\(mergedResult.revision) blocks=\(mergedResult.blocks.count) "
                        + "journals=\(mergedResult.blocks.filter { $0.journalDay != nil }.count) "
                        + "graphs=\(mergedResult.graphs?.count ?? 0) "
                        + "patch=\(result.isOutlinerPatch) "
                        + "applyMs=\(String(format: "%.2f", applyMilliseconds))"
                )
                #endif
                logger.info(
                    "Core action applied: \(actionName), revision: \(mergedResult.revision), blocks: \(mergedResult.blocks.count), graph: \(mergedResult.graphName ?? "none")"
                )
                snapshot = mergedResult
                lastError = nil
                if actionName == "openGraph" {
                    activeGraphID = mergedResult.selectedGraphId
                    debugDatabaseRoute = "graph:\(activeGraphID ?? "unknown")"
                } else if actionName == "open" {
                    activeGraphID = nil
                    debugDatabaseRoute = "catalog:\(openedDatabasePath ?? "unknown")"
                }
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

    private static func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    #if !SKIP
    private static func corePriority(for action: String) -> LogseqChatCorePriority {
        switch action {
        case "outlinerEvent", "selectPage", "clearSelectedPage", "openNode", "closeNode",
             "select", "clearSelection", "loadOlderJournals", "loadBlockReferences",
             "loadPageReferences", "loadTagObjects", "searchNodes", "send", "sendTask",
             "addAsset", "addChildBlock", "updateBlock", "updateBlockStatus", "deleteBlock":
            return .interaction
        case "open", "configure", "refresh", "refreshGraphCatalog", "createSyncGraph", "openGraph",
             "importSnapshot", "startSSE", "feedSSE", "stopSSE", "beginPendingSync",
             "completePendingSync", "cancelPendingSync":
            return .maintenance
        default:
            return .normal
        }
    }
    #endif

    private func mergedSnapshot(_ result: LogseqChatSnapshot) -> LogseqChatSnapshot {
        if result.isPendingSyncPatch {
            return LogseqChatSnapshot(
                revision: result.revision,
                blocks: snapshot.blocks,
                selectedBlock: snapshot.selectedBlock,
                lastRefreshAt: snapshot.lastRefreshAt,
                graphName: snapshot.graphName,
                selectedGraphId: snapshot.selectedGraphId,
                graphs: snapshot.graphs,
                favorites: snapshot.favorites,
                recentPages: snapshot.recentPages,
                selectedPage: snapshot.selectedPage,
                selectedPageIsTag: snapshot.selectedPageIsTag,
                selectedPageIsProperty: snapshot.selectedPageIsProperty,
                appliedServerT: snapshot.appliedServerT,
                syncConnected: snapshot.syncConnected,
                relatedBlocks: snapshot.relatedBlocks,
                linkedReferenceBlocks: snapshot.linkedReferenceBlocks,
                searchQuery: snapshot.searchQuery,
                searchResults: snapshot.searchResults,
                flashcards: snapshot.flashcards,
                nodeRoutes: snapshot.nodeRoutes,
                taskStatuses: snapshot.taskStatuses,
                isGraphEncrypted: snapshot.isGraphEncrypted,
                isGraphUnlocked: snapshot.isGraphUnlocked,
                pendingSyncRequest: result.pendingSyncRequest,
                outlinerState: snapshot.outlinerState,
                outlinerCommandRevision: snapshot.outlinerCommandRevision,
                outlinerCommands: snapshot.outlinerCommands,
                outlinerAutocompleteCandidates: snapshot.outlinerAutocompleteCandidates,
                outlinerRows: snapshot.outlinerRows,
                hasPendingSemanticOperations: result.hasPendingSemanticOperations,
                hasOlderJournals: snapshot.hasOlderJournals
            )
        }
        if result.isOutlinerPatch {
            let deletedBlockIDs = Set(result.deletedBlockIds)
            let replacementBlocks = Dictionary(
                uniqueKeysWithValues: result.blocks.map { ($0.uuid, $0) }
            )
            var mergedBlockIDs = Set<String>()
            var blocks: [LogseqBlock] = snapshot.blocks.compactMap { block in
                guard !deletedBlockIDs.contains(block.uuid) else { return nil }
                mergedBlockIDs.insert(block.uuid)
                return replacementBlocks[block.uuid] ?? block
            }
            for block in result.blocks where !mergedBlockIDs.contains(block.uuid) {
                blocks.append(block)
                mergedBlockIDs.insert(block.uuid)
            }

            var outlinerRows = snapshot.outlinerRows
            if !result.outlinerRowSplices.isEmpty {
                for splice in result.outlinerRowSplices {
                    let requestedStart: Int?
                    if let afterBlockId = splice.afterBlockId,
                       let anchor = outlinerRows.firstIndex(where: {
                           $0.block.uuid == afterBlockId
                       }) {
                        requestedStart = anchor + 1
                    } else if let beforeBlockId = splice.beforeBlockId,
                              let anchor = outlinerRows.firstIndex(where: {
                                  $0.block.uuid == beforeBlockId
                              }) {
                        requestedStart = anchor
                    } else {
                        requestedStart = splice.start
                    }
                    guard let requestedStart else { continue }
                    let start = min(max(requestedStart, 0), outlinerRows.count)
                    let deleteEnd = min(
                        start + max(splice.deleteCount, 0),
                        outlinerRows.count
                    )
                    let insertedBlockIDs = Set(splice.rows.map { $0.block.uuid })
                    var nextRows: [LogseqOutlineRow] = []
                    var index = 0
                    while index < start {
                        if !insertedBlockIDs.contains(outlinerRows[index].block.uuid) {
                            nextRows.append(outlinerRows[index])
                        }
                        index += 1
                    }
                    for row in splice.rows {
                        nextRows.append(row)
                    }
                    index = deleteEnd
                    while index < outlinerRows.count {
                        if !insertedBlockIDs.contains(outlinerRows[index].block.uuid) {
                            nextRows.append(outlinerRows[index])
                        }
                        index += 1
                    }
                    outlinerRows = nextRows
                }
            } else if !result.outlinerRows.isEmpty {
                let replacementRows = Dictionary(
                    uniqueKeysWithValues: result.outlinerRows.map {
                        ($0.block.uuid, $0)
                    }
                )
                outlinerRows = outlinerRows.map { row in
                    replacementRows[row.block.uuid] ?? row
                }
            }
            outlinerRows = outlinerRows.compactMap { row in
                guard !deletedBlockIDs.contains(row.block.uuid) else { return nil }
                guard let block = replacementBlocks[row.block.uuid] else { return row }
                return LogseqOutlineRow(
                    block: block,
                    depth: row.depth,
                    hasChildren: row.hasChildren,
                    isCollapsed: row.isCollapsed
                )
            }
            var visibleRowIDs = Set<String>()
            outlinerRows = outlinerRows.filter { row in
                guard !visibleRowIDs.contains(row.block.uuid) else { return false }
                visibleRowIDs.insert(row.block.uuid)
                return true
            }

            let selectedBlock: LogseqBlock? = snapshot.selectedBlock.flatMap { selected in
                guard !deletedBlockIDs.contains(selected.uuid) else { return nil }
                return replacementBlocks[selected.uuid] ?? selected
            }
            return LogseqChatSnapshot(
                revision: snapshot.revision,
                blocks: blocks,
                selectedBlock: selectedBlock,
                lastRefreshAt: snapshot.lastRefreshAt,
                graphName: snapshot.graphName,
                selectedGraphId: snapshot.selectedGraphId,
                graphs: snapshot.graphs,
                favorites: snapshot.favorites,
                recentPages: snapshot.recentPages,
                selectedPage: snapshot.selectedPage,
                selectedPageIsTag: snapshot.selectedPageIsTag,
                selectedPageIsProperty: snapshot.selectedPageIsProperty,
                appliedServerT: snapshot.appliedServerT,
                syncConnected: snapshot.syncConnected,
                relatedBlocks: snapshot.relatedBlocks,
                linkedReferenceBlocks: snapshot.linkedReferenceBlocks,
                searchQuery: snapshot.searchQuery,
                searchResults: snapshot.searchResults,
                flashcards: snapshot.flashcards,
                nodeRoutes: snapshot.nodeRoutes,
                taskStatuses: snapshot.taskStatuses,
                isGraphEncrypted: snapshot.isGraphEncrypted,
                isGraphUnlocked: snapshot.isGraphUnlocked,
                pendingSyncRequest: snapshot.pendingSyncRequest,
                outlinerState: result.outlinerState,
                outlinerCommandRevision: result.outlinerCommandRevision,
                outlinerCommands: result.outlinerCommands,
                outlinerAutocompleteCandidates: result.outlinerAutocompleteCandidates,
                outlinerRows: outlinerRows,
                hasPendingSemanticOperations: result.hasPendingSemanticOperations,
                hasOlderJournals: snapshot.hasOlderJournals,
                isOutlinerPatch: false
            )
        }
        if let mutationServerT, let appliedServerT = result.appliedServerT,
           appliedServerT > mutationServerT {
            cursorAdvancedAfterMutation = true
            self.mutationServerT = nil
        }
        return LogseqChatSnapshot(
            revision: result.revision,
            blocks: result.blocks,
            selectedBlock: result.selectedBlock,
            lastRefreshAt: result.lastRefreshAt,
            graphName: result.graphName,
            selectedGraphId: result.selectedGraphId,
            graphs: result.graphs ?? snapshot.graphs,
            favorites: result.favorites,
            recentPages: result.recentPages,
            selectedPage: result.selectedPage,
            selectedPageIsTag: result.selectedPageIsTag,
            selectedPageIsProperty: result.selectedPageIsProperty,
            appliedServerT: result.appliedServerT,
            syncConnected: result.syncConnected,
            relatedBlocks: result.relatedBlocks,
            linkedReferenceBlocks: result.linkedReferenceBlocks,
            searchQuery: result.searchQuery,
            searchResults: result.searchResults,
            flashcards: result.flashcards,
            nodeRoutes: result.nodeRoutes,
            taskStatuses: result.taskStatuses ?? snapshot.taskStatuses,
            isGraphEncrypted: result.isGraphEncrypted,
            isGraphUnlocked: result.isGraphUnlocked,
            pendingSyncRequest: result.pendingSyncRequest,
            outlinerState: result.outlinerState,
            outlinerCommandRevision: result.outlinerCommandRevision,
            outlinerCommands: result.outlinerCommands,
            outlinerAutocompleteCandidates: result.outlinerAutocompleteCandidates,
            outlinerRows: result.outlinerRows,
            hasPendingSemanticOperations: result.hasPendingSemanticOperations,
            hasOlderJournals: result.hasOlderJournals
        )
    }

}
