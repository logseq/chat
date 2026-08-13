import Foundation
import Observation
import OSLog
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

public struct LogseqBlock: Codable, Identifiable, Hashable {
    public let uuid: String
    public let kind: String
    public let title: String
    public let pageId: String
    public let parentId: String?
    public let createdAt: Int64
    public let updatedAt: Int64

    public var id: String { uuid }

    public var createdDate: Date {
        Date(timeIntervalSince1970: Double(createdAt) / 1000.0)
    }

    public var dayTitle: String {
        Self.dayFormatter.string(from: createdDate)
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
    public let blocks: [LogseqBlock]
}

public struct LogseqChatSnapshot: Codable {
    public let revision: Int
    public let query: String
    public let blocks: [LogseqBlock]
    public let selectedBlock: LogseqBlock?
    public let lastRefreshAt: Int64?
    public let isSearching: Bool
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
}

@Observable public final class LogseqChatStore {
    public private(set) var snapshot = LogseqChatSnapshot(
        revision: 0,
        query: "",
        blocks: [],
        selectedBlock: nil,
        lastRefreshAt: nil,
        isSearching: false
    )
    public private(set) var lastError: LogseqChatCoreError?
    public private(set) var isRefreshing = false

    private let callCore: (String) -> String

    public init(call: @escaping (String) -> String) {
        self.callCore = call
    }

    public var sections: [LogseqBlockSection] {
        var grouped: [LogseqBlockSection] = []
        let chronologicalBlocks = snapshot.blocks.sorted { left, right in
            if left.createdAt == right.createdAt {
                return left.uuid < right.uuid
            }
            return left.createdAt < right.createdAt
        }
        for block in chronologicalBlocks {
            if let last = grouped.last, last.id == block.dayTitle {
                grouped[grouped.count - 1] = LogseqBlockSection(
                    id: last.id,
                    blocks: last.blocks + [block]
                )
            } else {
                grouped.append(LogseqBlockSection(id: block.dayTitle, blocks: [block]))
            }
        }
        return grouped
    }

    public func open(path: String) {
        perform(LogseqChatRPCRequest(method: "open", params: LogseqChatRPCParams(action: nil, path: path)))
    }

    public func configure(baseURL: String, token: String) {
        let payload = """
        {"baseUrl":"\(Self.escape(baseURL))","token":"\(Self.escape(token))"}
        """
        perform(LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "configure", payload: payload)))
    }

    public func refresh() {
        isRefreshing = true
        perform(LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "refresh")))
        isRefreshing = false
    }

    public func search(_ query: String) {
        perform(LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "search", payload: query)))
    }

    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        perform(LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "send", payload: trimmed)))
    }

    public func update(block: LogseqBlock, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let payloadData = try JSONEncoder().encode(UpdateBlockPayload(uuid: block.uuid, title: trimmed))
            guard let payload = String(data: payloadData, encoding: .utf8) else {
                lastError = LogseqChatCoreError(code: "request_encoding", message: "Could not encode update payload")
                return
            }
            perform(LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "updateBlock", payload: payload)))
        } catch {
            lastError = LogseqChatCoreError(code: "request_encoding", message: "\(error)")
        }
    }

    public func select(_ block: LogseqBlock) {
        perform(LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "select", payload: block.uuid)))
    }

    public func clearSelection() {
        perform(LogseqChatRPCRequest(method: "dispatch", params: LogseqChatRPCParams(action: "clearSelection")))
    }

    @MainActor public func runRefreshLoop() async {
        refresh()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            refresh()
        }
    }

    private func perform(_ request: LogseqChatRPCRequest) {
        do {
            let requestData = try JSONEncoder().encode(request)
            guard let requestJSON = String(data: requestData, encoding: .utf8) else {
                lastError = LogseqChatCoreError(code: "request_encoding", message: "Could not encode request")
                return
            }
            let responseJSON = callCore(requestJSON)
            let responseData = Data(responseJSON.utf8)
            let response = try JSONDecoder().decode(LogseqChatRPCResponse.self, from: responseData)
            if response.ok, let result = response.result {
                snapshot = result
                lastError = nil
            } else {
                lastError = response.error ?? LogseqChatCoreError(code: "unknown_core_error", message: "The core returned no snapshot")
            }
        } catch {
            lastError = LogseqChatCoreError(code: "response_decoding", message: "\(error)")
        }
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
