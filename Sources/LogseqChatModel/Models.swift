import Foundation

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
