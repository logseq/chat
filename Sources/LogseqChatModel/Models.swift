import Foundation

public enum LogseqContentMode: String, Codable, Sendable {
    case chat
    case outliner

    public var toggled: Self {
        self == .chat ? .outliner : .chat
    }

    public func presentationMode(
        isSearching: Bool,
        hasSelectedPage: Bool = false
    ) -> Self {
        hasSelectedPage ? .outliner : self
    }

    public static func supportsModeSwitch(hasSelectedPage: Bool) -> Bool {
        !hasSelectedPage
    }
}

public struct LogseqEntitySummary: Codable, Hashable, Identifiable, Sendable {
    public let uuid: String
    public let title: String
    public var id: String { uuid }

    public init(uuid: String, title: String) {
        self.uuid = uuid
        self.title = title
    }
}

public enum LogseqMarkupNodeType: String, Codable, Hashable, Sendable {
    case text
    case emphasis
    case code
    case link
    case nodeReference
    case tagReference
}

public struct LogseqMarkupNode: Codable, Hashable, Sendable {
    public let type: LogseqMarkupNodeType
    public let text: String?
    public let style: String?
    public let url: String?
    public let uuid: String?
    public let title: String?
    public let children: [LogseqMarkupNode]

    public init(
        type: LogseqMarkupNodeType,
        text: String? = nil,
        style: String? = nil,
        url: String? = nil,
        uuid: String? = nil,
        title: String? = nil,
        children: [LogseqMarkupNode] = []
    ) {
        self.type = type
        self.text = text
        self.style = style
        self.url = url
        self.uuid = uuid
        self.title = title
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, style, url, uuid, title, children
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(LogseqMarkupNodeType.self, forKey: .type)
        text = try values.decodeIfPresent(String.self, forKey: .text)
        style = try values.decodeIfPresent(String.self, forKey: .style)
        url = try values.decodeIfPresent(String.self, forKey: .url)
        uuid = try values.decodeIfPresent(String.self, forKey: .uuid)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        children = try values.decodeIfPresent([LogseqMarkupNode].self, forKey: .children) ?? []
    }
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

    public static func availableChoices(catalog: [Self]) -> [Self] {
        var result: [Self] = []
        var identities = Set<String>()
        for status in catalog + builtIn {
            let identity = status.ident ?? status.uuid
            if identities.insert(identity).inserted {
                result.append(status)
            }
        }
        return result
    }
}

public struct LogseqBlock: Codable, Identifiable, Hashable {
    public let uuid: String
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
    public let breadcrumbs: [LogseqEntitySummary]
    public let markup: [LogseqMarkupNode]
    public let status: LogseqTaskStatus?
    public let isAsset: Bool
    public let assetType: String?
    public let assetSize: Int?
    public let assetChecksum: String?
    public let localPath: String?

    public init(
        uuid: String,
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
        breadcrumbs: [LogseqEntitySummary] = [],
        markup: [LogseqMarkupNode] = [],
        status: LogseqTaskStatus? = nil,
        isAsset: Bool = false,
        assetType: String? = nil,
        assetSize: Int? = nil,
        assetChecksum: String? = nil,
        localPath: String? = nil
    ) {
        self.uuid = uuid
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
        self.breadcrumbs = breadcrumbs
        self.markup = markup
        self.status = status
        self.isAsset = isAsset
        self.assetType = assetType
        self.assetSize = assetSize
        self.assetChecksum = assetChecksum
        self.localPath = localPath
    }

    private enum CodingKeys: String, CodingKey {
        case uuid, title, pageId, parentId, order, createdAt, updatedAt, syncStatus
        case journalTitle, journalDay, tags, references, breadcrumbs, markup, status, isAsset, assetType, assetSize
        case assetChecksum, localPath
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try values.decode(String.self, forKey: .uuid)
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
        breadcrumbs = try values.decodeIfPresent([LogseqEntitySummary].self, forKey: .breadcrumbs) ?? []
        markup = try values.decodeIfPresent([LogseqMarkupNode].self, forKey: .markup) ?? []
        status = try values.decodeIfPresent(LogseqTaskStatus.self, forKey: .status)
        isAsset = try values.decodeIfPresent(Bool.self, forKey: .isAsset) ?? false
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

public struct LogseqOutlineRow: Codable, Identifiable, Hashable {
    public let block: LogseqBlock
    public let depth: Int
    public let hasChildren: Bool
    public let isCollapsed: Bool
    public var id: String { block.uuid }
}

public struct LogseqGraph: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let isEncrypted: Bool
    public let isReady: Bool
}

public struct LogseqSidebarPage: Codable, Hashable, Identifiable, Sendable {
    public let uuid: String
    public let title: String
    public var id: String { uuid }
}

public struct LogseqNodeProjection: Codable, Identifiable {
    public let uuid: String
    public let isTag: Bool
    public let page: LogseqSidebarPage
    public let blocks: [LogseqBlock]
    public let relatedBlocks: [LogseqBlock]
    public let outlinerState: LogseqOutlinerState
    public let outlinerRows: [LogseqOutlineRow]
    public let outlinerAutocompleteCandidates: [LogseqOutlinerAutocompleteCandidate]
    public var id: String { uuid }
}

public struct LogseqNodeRouteRequest: Codable, Sendable {
    public let uuid: String

    public init(uuid: String) {
        self.uuid = uuid
    }
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

public enum LogseqOutlinerAutocompleteKind: String, Codable, Sendable {
    case node, tag, property
}

public struct LogseqOutlinerEditing: Codable, Equatable, Sendable {
    public let uuid: String
    public let title: String
    public let caretUTF16Offset: Int
}

public struct LogseqOutlinerAutocomplete: Codable, Equatable, Sendable {
    public let kind: LogseqOutlinerAutocompleteKind
    public let query: String
}

public struct LogseqOutlinerAutocompleteCandidate: Codable, Equatable, Identifiable, Sendable {
    public let label: String
    public let value: String
    public var id: String { "\(label)|\(value)" }
}

public struct LogseqOutlinerState: Codable, Equatable, Sendable {
    public let editing: LogseqOutlinerEditing?
    public let selectedBlockIds: [String]
    public let autocomplete: LogseqOutlinerAutocomplete?
    public let collapsedBlockIds: [String]
    public let zoomedBlockIds: [String]
    public var zoomedBlockId: String? { zoomedBlockIds.last }

    public static let empty = Self(
        editing: nil,
        selectedBlockIds: [],
        autocomplete: nil,
        collapsedBlockIds: [],
        zoomedBlockIds: []
    )
}

public struct LogseqOutlinerCommand: Codable, Equatable, Sendable {
    public let type: String
    public let style: String?
    public let uuid: String?
    public let uuids: [String]?
    public let text: String?
}

public struct LogseqOutlinerEvent: Encodable, Sendable {
    public let type: String
    public var uuid: String?
    public var title: String?
    public var caretUTF16Offset: Int?
    public var selectionLength: Int?
    public var action: String?
    public var targetUuid: String?
    public var placement: String?
    public var value: String?
    public var statusIdent: String?
    public var statusUuid: String?

    public init(
        type: String,
        uuid: String? = nil,
        title: String? = nil,
        caretUTF16Offset: Int? = nil,
        selectionLength: Int? = nil,
        action: String? = nil,
        targetUuid: String? = nil,
        placement: String? = nil,
        value: String? = nil,
        statusIdent: String? = nil,
        statusUuid: String? = nil
    ) {
        self.type = type
        self.uuid = uuid
        self.title = title
        self.caretUTF16Offset = caretUTF16Offset
        self.selectionLength = selectionLength
        self.action = action
        self.targetUuid = targetUuid
        self.placement = placement
        self.value = value
        self.statusIdent = statusIdent
        self.statusUuid = statusUuid
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
    public let favorites: [LogseqSidebarPage]
    public let recentPages: [LogseqSidebarPage]
    public let selectedPage: LogseqSidebarPage?
    public let selectedPageIsTag: Bool?
    public let appliedServerT: Int?
    public let syncConnected: Bool?
    public let isSearching: Bool
    public let relatedBlocks: [LogseqBlock]?
    public let nodeRoutes: [LogseqNodeProjection]
    public let taskStatuses: [LogseqTaskStatus]?
    public let isGraphEncrypted: Bool?
    public let isGraphUnlocked: Bool?
    public let pendingSyncRequest: LogseqPendingSyncRequest?
    public let outlinerState: LogseqOutlinerState
    public let outlinerCommandRevision: Int
    public let outlinerCommands: [LogseqOutlinerCommand]
    public let outlinerAutocompleteCandidates: [LogseqOutlinerAutocompleteCandidate]
    public let outlinerRows: [LogseqOutlineRow]
    public let hasPendingSemanticOperations: Bool
    public let hasOlderJournals: Bool
    public let isOutlinerPatch: Bool

    public init(
        revision: Int, query: String, blocks: [LogseqBlock], selectedBlock: LogseqBlock?,
        lastRefreshAt: Int64?, graphName: String?, isSearching: Bool,
        selectedGraphId: String? = nil, graphs: [LogseqGraph]? = nil,
        favorites: [LogseqSidebarPage] = [], recentPages: [LogseqSidebarPage] = [],
        selectedPage: LogseqSidebarPage? = nil,
        selectedPageIsTag: Bool? = nil,
        appliedServerT: Int? = nil, syncConnected: Bool? = nil,
        relatedBlocks: [LogseqBlock]? = nil,
        nodeRoutes: [LogseqNodeProjection] = [],
        taskStatuses: [LogseqTaskStatus]? = nil,
        isGraphEncrypted: Bool? = nil,
        isGraphUnlocked: Bool? = nil,
        pendingSyncRequest: LogseqPendingSyncRequest? = nil,
        outlinerState: LogseqOutlinerState = .empty,
        outlinerCommandRevision: Int = 0,
        outlinerCommands: [LogseqOutlinerCommand] = [],
        outlinerAutocompleteCandidates: [LogseqOutlinerAutocompleteCandidate] = [],
        outlinerRows: [LogseqOutlineRow] = [],
        hasPendingSemanticOperations: Bool = false,
        hasOlderJournals: Bool = false,
        isOutlinerPatch: Bool = false
    ) {
        self.revision = revision
        self.query = query
        self.blocks = blocks
        self.selectedBlock = selectedBlock
        self.lastRefreshAt = lastRefreshAt
        self.graphName = graphName
        self.selectedGraphId = selectedGraphId
        self.graphs = graphs
        self.favorites = favorites
        self.recentPages = recentPages
        self.selectedPage = selectedPage
        self.selectedPageIsTag = selectedPageIsTag
        self.appliedServerT = appliedServerT
        self.syncConnected = syncConnected
        self.isSearching = isSearching
        self.relatedBlocks = relatedBlocks
        self.nodeRoutes = nodeRoutes
        self.taskStatuses = taskStatuses
        self.isGraphEncrypted = isGraphEncrypted
        self.isGraphUnlocked = isGraphUnlocked
        self.pendingSyncRequest = pendingSyncRequest
        self.outlinerState = outlinerState
        self.outlinerCommandRevision = outlinerCommandRevision
        self.outlinerCommands = outlinerCommands
        self.outlinerAutocompleteCandidates = outlinerAutocompleteCandidates
        self.outlinerRows = outlinerRows
        self.hasPendingSemanticOperations = hasPendingSemanticOperations
        self.hasOlderJournals = hasOlderJournals
        self.isOutlinerPatch = isOutlinerPatch
    }

    private enum CodingKeys: String, CodingKey {
        case revision, query, blocks, selectedBlock, lastRefreshAt, graphName
        case selectedGraphId, graphs, favorites, recentPages, selectedPage, selectedPageIsTag, appliedServerT
        case syncConnected, isSearching, relatedBlocks, nodeRoutes, taskStatuses
        case isGraphEncrypted, isGraphUnlocked, pendingSyncRequest
        case outlinerState, outlinerCommandRevision, outlinerCommands
        case outlinerAutocompleteCandidates
        case outlinerRows
        case hasPendingSemanticOperations
        case hasOlderJournals
        case isOutlinerPatch
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        revision = try values.decode(Int.self, forKey: .revision)
        query = try values.decode(String.self, forKey: .query)
        blocks = try values.decode([LogseqBlock].self, forKey: .blocks)
        selectedBlock = try values.decodeIfPresent(LogseqBlock.self, forKey: .selectedBlock)
        lastRefreshAt = try values.decodeIfPresent(Int64.self, forKey: .lastRefreshAt)
        graphName = try values.decodeIfPresent(String.self, forKey: .graphName)
        selectedGraphId = try values.decodeIfPresent(String.self, forKey: .selectedGraphId)
        graphs = try values.decodeIfPresent([LogseqGraph].self, forKey: .graphs)
        favorites = try values.decodeIfPresent([LogseqSidebarPage].self, forKey: .favorites) ?? []
        recentPages = try values.decodeIfPresent([LogseqSidebarPage].self, forKey: .recentPages) ?? []
        selectedPage = try values.decodeIfPresent(LogseqSidebarPage.self, forKey: .selectedPage)
        selectedPageIsTag = try values.decodeIfPresent(Bool.self, forKey: .selectedPageIsTag)
        appliedServerT = try values.decodeIfPresent(Int.self, forKey: .appliedServerT)
        syncConnected = try values.decodeIfPresent(Bool.self, forKey: .syncConnected)
        isSearching = try values.decode(Bool.self, forKey: .isSearching)
        relatedBlocks = try values.decodeIfPresent([LogseqBlock].self, forKey: .relatedBlocks)
        nodeRoutes = try values.decodeIfPresent(
            [LogseqNodeProjection].self, forKey: .nodeRoutes
        ) ?? []
        taskStatuses = try values.decodeIfPresent([LogseqTaskStatus].self, forKey: .taskStatuses)
        isGraphEncrypted = try values.decodeIfPresent(Bool.self, forKey: .isGraphEncrypted)
        isGraphUnlocked = try values.decodeIfPresent(Bool.self, forKey: .isGraphUnlocked)
        pendingSyncRequest = try values.decodeIfPresent(LogseqPendingSyncRequest.self, forKey: .pendingSyncRequest)
        outlinerState = try values.decodeIfPresent(LogseqOutlinerState.self, forKey: .outlinerState) ?? .empty
        outlinerCommandRevision = try values.decodeIfPresent(Int.self, forKey: .outlinerCommandRevision) ?? 0
        outlinerCommands = try values.decodeIfPresent([LogseqOutlinerCommand].self, forKey: .outlinerCommands) ?? []
        outlinerAutocompleteCandidates = try values.decodeIfPresent(
            [LogseqOutlinerAutocompleteCandidate].self,
            forKey: .outlinerAutocompleteCandidates
        ) ?? []
        outlinerRows = try values.decodeIfPresent([LogseqOutlineRow].self, forKey: .outlinerRows) ?? []
        hasPendingSemanticOperations = try values.decodeIfPresent(Bool.self, forKey: .hasPendingSemanticOperations) ?? false
        hasOlderJournals = try values.decodeIfPresent(Bool.self, forKey: .hasOlderJournals) ?? false
        isOutlinerPatch = try values.decodeIfPresent(Bool.self, forKey: .isOutlinerPatch) ?? false
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
