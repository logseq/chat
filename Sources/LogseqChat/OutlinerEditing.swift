import SwiftUI
import LogseqChatModel

enum BlockEditPresentation: Equatable {
    case composer
    case inline
}

enum BlockEditingPolicy {
    static func presentation(for contentMode: LogseqContentMode) -> BlockEditPresentation {
        contentMode == .outliner ? .inline : .composer
    }
}

enum BlockSelectionActivation: Equatable {
    case longPress
}

enum BlockSelectionGesturePolicy {
    static let activation = BlockSelectionActivation.longPress
}

enum OutlinerClipboardPolicy {
    static func nodeReferences(_ uuids: [String]) -> String {
        uuids.map { "[[\($0)]]" }.joined(separator: "\n")
    }
}

enum OutlinerMarkupLink: Equatable {
    case node(uuid: String)

    var url: URL? {
        switch self { case let .node(uuid): return URL(string: "logseq-node://\(uuid)") }
    }

    init?(url: URL) {
        guard let uuid = url.host, !uuid.isEmpty else { return nil }
        switch url.scheme {
        case "logseq-node":
            self = .node(uuid: uuid)
        default:
            return nil
        }
    }
}

struct OutlinerMarkupPresentation: Equatable {
    let plainText: String
    let links: [OutlinerMarkupLink]

    static func make(nodes: [LogseqMarkupNode], fallback: String) -> Self {
        guard !nodes.isEmpty else { return Self(plainText: fallback, links: []) }
        var text = ""
        var links: [OutlinerMarkupLink] = []

        func append(_ nodes: [LogseqMarkupNode]) {
            for node in nodes {
                switch node.type {
                case .text, .code:
                    text += node.text ?? ""
                case .emphasis:
                    append(node.children)
                case .link:
                    if node.children.isEmpty {
                        text += node.url ?? ""
                    } else {
                        append(node.children)
                    }
                case .nodeReference:
                    text += node.title ?? ""
                    if let uuid = node.uuid {
                        links.append(.node(uuid: uuid))
                    }
                case .tagReference:
                    text += "#" + (node.title ?? "")
                    if let uuid = node.uuid {
                        links.append(.node(uuid: uuid))
                    }
                }
            }
        }

        append(nodes)
        return Self(plainText: text, links: links)
    }
}

enum BlockTagPresentationPolicy {
    static func inlineTagIDs(_ nodes: [LogseqMarkupNode]) -> Set<String> {
        var result: Set<String> = []
        collectInlineTagIDs(nodes, into: &result)
        return result
    }

    static func trailingTags(
        tags: [LogseqEntitySummary],
        markup: [LogseqMarkupNode]
    ) -> [LogseqEntitySummary] {
        let inlineIDs = inlineTagIDs(markup)
        var seen: Set<String> = []
        return tags.filter { tag in
            !inlineIDs.contains(tag.uuid)
                && seen.insert(tag.uuid).inserted
        }
    }

    private static func collectInlineTagIDs(
        _ nodes: [LogseqMarkupNode],
        into result: inout Set<String>
    ) {
        for node in nodes {
            if node.type == .tagReference, let uuid = node.uuid {
                result.insert(uuid)
            }
            collectInlineTagIDs(node.children, into: &result)
        }
    }
}

enum InlineEditorTextReconciliationDecision: Equatable {
    case keepLocal
    case acknowledgeLocal
    case applyModel
}

enum InlineEditorTextReconciliationPolicy {
    /// While a Return-key handoff is pending, the editor keeps showing the
    /// full pre-split text at the old block position and applies the model
    /// text only in the same render pass that moves the editor to the new
    /// block, so the split appears atomically without flicker.
    static func decision(
        modelText: String,
        localText: String?,
        isSameBlock: Bool = true,
        isAwaitingBlockHandoff: Bool = false
    ) -> InlineEditorTextReconciliationDecision {
        if isAwaitingBlockHandoff {
            return isSameBlock ? .keepLocal : .applyModel
        }
        guard let localText else { return .applyModel }
        if modelText == localText { return .acknowledgeLocal }
        if !isSameBlock { return .applyModel }
        return .keepLocal
    }
}

enum InlineEditorHandoffMerge {
    /// Keystrokes swallowed while a Return handoff was pending are inserted
    /// at the caret the core requested for the new block.
    static func merged(
        modelText: String,
        desiredCaretUTF16Offset: Int?,
        bufferedTyping: String
    ) -> (text: String, caretUTF16Offset: Int) {
        let value = modelText as NSString
        let caret = min(max(desiredCaretUTF16Offset ?? value.length, 0), value.length)
        guard !bufferedTyping.isEmpty else { return (modelText, caret) }
        let text = value.replacingCharacters(
            in: NSRange(location: caret, length: 0),
            with: bufferedTyping
        )
        return (text, caret + (bufferedTyping as NSString).length)
    }
}

enum InlineEditorFocusPolicy {
    static func shouldRequestFocus(
        isAttachedToWindow: Bool,
        isFirstResponder: Bool
    ) -> Bool {
        isAttachedToWindow && !isFirstResponder
    }
}

struct OutlinerRowRenderKey: Equatable, @unchecked Sendable {
    let row: LogseqOutlineRow
    let statuses: [LogseqTaskStatus]
    let isEditing: Bool
    let isSelected: Bool
    let isSelectionActive: Bool
    let editingTitle: String
    let desiredCaretUTF16Offset: Int?
}

enum OutlinerToolbarAction: Hashable {
    case task
    case outdent
    case indent
    case tag
    case pageReference
    case camera
    case attachment
    case hideKeyboard
    case copy
    case delete
    case copyReference
    case copyURL
    case unselect
    case undo
    case redo

    var eventValue: String? {
        switch self {
        case .task: return "task"
        case .outdent: return "outdent"
        case .indent: return "indent"
        case .tag: return "tag"
        case .pageReference: return "pageReference"
        case .camera: return "camera"
        case .attachment: return "attachment"
        case .hideKeyboard: return "hideKeyboard"
        case .copy: return "copy"
        case .delete: return "delete"
        case .copyReference: return "copyReference"
        case .copyURL: return "copyURL"
        case .unselect: return "unselect"
        case .undo, .redo: return nil
        }
    }

    var systemImageName: String {
        switch self {
        case .task: return "checkmark.square"
        case .outdent: return "arrow.left"
        case .indent: return "arrow.right"
        case .tag: return "number"
        case .camera: return "camera"
        case .attachment: return "paperclip"
        case .pageReference: return "parentheses"
        case .hideKeyboard: return "keyboard.chevron.compact.down"
        case .copy: return "doc.on.doc"
        case .delete: return "trash"
        case .copyReference: return "r.square"
        case .copyURL: return "link"
        case .unselect: return "xmark"
        case .undo: return "arrow.uturn.backward"
        case .redo: return "arrow.uturn.forward"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .task: return "Task"
        case .outdent: return "Outdent"
        case .indent: return "Indent"
        case .tag: return "Tag"
        case .pageReference: return "Page reference"
        case .camera: return "Photo"
        case .attachment: return "Upload asset"
        case .hideKeyboard: return "Hide keyboard"
        case .copy: return "Copy"
        case .delete: return "Delete"
        case .copyReference: return "Copy reference"
        case .copyURL: return "Copy URL"
        case .unselect: return "Unselect"
        case .undo: return "Undo"
        case .redo: return "Redo"
        }
    }

    var preservesInlineEditorFocus: Bool {
        switch self {
        case .task, .outdent, .indent, .tag, .pageReference:
            return true
        case .camera, .attachment, .hideKeyboard, .copy, .delete,
             .copyReference, .copyURL, .unselect, .undo, .redo:
            return false
        }
    }
}

enum OutlinerToolbarPolicy {
    static let editorItemWidth: CGFloat = 42
    static let selectionItemWidth: CGFloat = 58
    static let selectionItemSpacing: CGFloat = 6
    static let iconSize: CGFloat = 18
    static let iconBoxSize: CGFloat = 22
    static let captionHeight: CGFloat = 14

    static let editorActions: [OutlinerToolbarAction] = [
        .task, .outdent, .indent, .tag, .camera, .attachment,
        .pageReference,
    ]

    static let trailingEditorAction = OutlinerToolbarAction.hideKeyboard

    static let selectionActions: [OutlinerToolbarAction] = [
        .copy, .outdent, .indent, .delete, .copyReference, .copyURL,
    ]

    static let trailingSelectionAction = OutlinerToolbarAction.unselect
}

enum OutlinerKeyboardPresentationPolicy {
    static func presentedEditing(
        coreEditing: LogseqOutlinerEditing?,
        dismissalPending: Bool
    ) -> LogseqOutlinerEditing? {
        dismissalPending ? nil : coreEditing
    }
}

enum OutlinerLayoutMetrics {
    static let outerHorizontalInset: CGFloat = 8
    static let indentation: CGFloat = 22
    static let bulletHitSize: CGFloat = 24
    static let rootBulletCenterX = bulletHitSize / 2

    static func bulletCenterX(depth: Int) -> CGFloat {
        rootBulletCenterX + CGFloat(depth) * indentation
    }

    static func guideCenterX(level: Int) -> CGFloat {
        bulletCenterX(depth: level)
    }
}

enum OutlinerPaginationPolicy {
    static let buttonTitle = "Load earlier journals"
    static let accessibilityIdentifier = "button.outliner.load-older-journals"
}

enum OutlinerNavigationPolicy {
    static func backStepCount(presentedPath: [String], modelPath: [String]) -> Int {
        guard modelPath.starts(with: presentedPath) else { return 0 }
        return modelPath.count - presentedPath.count
    }

    static func pathAfterBackButton<Element>(_ path: [Element]) -> [Element] {
        path.isEmpty ? [] : Array(path.dropLast())
    }
}

enum AppNavigationRoute: Hashable {
    case node(String)
}

enum AppNavigationPathPolicy {
    static func nodeCount(_ path: [AppNavigationRoute]) -> Int { path.count }

    static func shouldAppend(_ route: AppNavigationRoute, to path: [AppNavigationRoute]) -> Bool {
        path.last != route
    }
}

enum RelatedContentPolicy {
    static func sectionTitle(isTag: Bool, hasBlocks: Bool) -> String? {
        isTag ? "Tagged nodes" : (hasBlocks ? "Linked references" : nil)
    }

    static func emptyTitle(isTag: Bool, hasBlocks: Bool) -> String? {
        isTag && !hasBlocks ? "No tagged nodes" : nil
    }
}

struct RelatedBlockGroup: Identifiable, Equatable {
    let id: String
    let breadcrumbs: [LogseqEntitySummary]
    let blocks: [LogseqBlock]
}

enum RelatedBlockGrouping {
    static func groups(_ blocks: [LogseqBlock]) -> [RelatedBlockGroup] {
        var order: [String] = []
        var breadcrumbsByID: [String: [LogseqEntitySummary]] = [:]
        var blocksByID: [String: [LogseqBlock]] = [:]
        for block in blocks {
            let key = block.breadcrumbs.last?.uuid ?? block.parentId ?? block.pageId
            if blocksByID[key] == nil {
                order.append(key)
                breadcrumbsByID[key] = block.breadcrumbs
                blocksByID[key] = []
            }
            blocksByID[key]!.append(block)
        }
        return order.map { key in
            RelatedBlockGroup(
                id: key,
                breadcrumbs: breadcrumbsByID[key]!,
                blocks: blocksByID[key]!
            )
        }
    }
}

enum OutlinerAccessibilityTitle {
    private static func displayTitle(_ title: String) -> String {
        title.isEmpty ? "Untitled block" : title
    }

    static func zoom(blockTitle: String) -> String {
        "Zoom into \(displayTitle(blockTitle))"
    }

    static func collapse(blockTitle: String, isCollapsed: Bool) -> String {
        "\(isCollapsed ? "Expand" : "Collapse") \(displayTitle(blockTitle))"
    }
}

enum OutlinerDropPlacement: Equatable {
    case before
    case inside
    case after

    var eventValue: String {
        switch self {
        case .before: return "before"
        case .inside: return "inside"
        case .after: return "after"
        }
    }
}

enum OutlinerDropZone {
    static func placement(locationY: CGFloat, rowHeight: CGFloat) -> OutlinerDropPlacement {
        let height = max(rowHeight, 1)
        if locationY < height * 0.25 { return .before }
        if locationY > height * 0.75 { return .after }
        return .inside
    }
}
