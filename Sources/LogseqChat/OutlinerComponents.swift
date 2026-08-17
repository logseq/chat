import SwiftUI
import LogseqChatModel
#if !SKIP && os(iOS)
import UIKit
import UniformTypeIdentifiers
#endif

struct OutlinerView: View {
    let rows: [LogseqOutlineRow]
    let sections: [LogseqBlockSection]
    let editing: LogseqOutlinerEditing?
    let selectedBlockIDs: Set<String>
    let statuses: [LogseqTaskStatus]
    let error: LogseqChatCoreError?
    let hasOlderJournals: Bool
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let sendEvent: (LogseqOutlinerEvent) -> Void
    let onBeginInteraction: () -> Void
    let onZoomBlock: (String) -> Void
    let onOpenMarkupLink: (OutlinerMarkupLink) -> Void
    let onLoadOlderJournals: () -> Void
    let relatedTitle: String?
    let relatedBlocks: [LogseqBlock]

    var body: some View {
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.block.uuid, $0) })
        let visibleSections = sections.filter { section in
            section.blocks.contains(where: { rowsByID[$0.uuid] != nil })
        }
        let content = ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: topPadding)
                if let error {
                    ErrorBanner(error: error)
                        .padding(.bottom, 12)
                }
                if rows.isEmpty {
                    EmptyBlocksView()
                } else {
                    ForEach(visibleSections) { section in
                        sectionView(section, rowsByID: rowsByID)
                    }
                }
                if hasOlderJournals {
                    Button(OutlinerPaginationPolicy.buttonTitle) {
                        onLoadOlderJournals()
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier(OutlinerPaginationPolicy.accessibilityIdentifier)
                }
                if let relatedTitle {
                    RelatedBlocksSection(
                        title: relatedTitle,
                        emptyTitle: nil,
                        blocks: relatedBlocks,
                        accessibilityIdentifier: "section.node.linked-references",
                        onOpenMarkupLink: onOpenMarkupLink
                    )
                    .padding(.top, 26)
                }
                Color.clear.frame(height: bottomPadding)
            }
            .padding(.horizontal, OutlinerLayoutMetrics.outerHorizontalInset)
        }
        .accessibilityIdentifier("list.outliner")
        #if !SKIP && os(iOS)
        content.overlayPreferenceValue(OutlinerEditorAnchorPreferenceKey.self) { anchors in
            GeometryReader { proxy in
                if let editing, let anchor = anchors[editing.uuid] {
                    let frame = proxy[anchor]
                    OutlinerInlineEditor(
                        text: editing.title,
                        blockID: editing.uuid,
                        desiredCaretUTF16Offset: editing.caretUTF16Offset,
                        onTextChange: { title, caret in
                            sendEvent(LogseqOutlinerEvent(
                                type: "textChanged",
                                title: title,
                                caretUTF16Offset: caret
                            ))
                        },
                        onReturn: { title, caret in
                            sendEvent(LogseqOutlinerEvent(
                                type: "returnPressed",
                                title: title,
                                caretUTF16Offset: caret
                            ))
                        },
                        onBackspace: { title, selectionLength in
                            sendEvent(LogseqOutlinerEvent(
                                type: "backspacePressed",
                                title: title,
                                selectionLength: selectionLength
                            ))
                        },
                        onCaretChange: { offset in
                            sendEvent(LogseqOutlinerEvent(
                                type: "caretMoved",
                                caretUTF16Offset: offset
                            ))
                        }
                    )
                    .frame(width: frame.width, height: max(frame.height, 24), alignment: .topLeading)
                    .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        #else
        content
        #endif
    }

    private func sectionView(
        _ section: LogseqBlockSection,
        rowsByID: [String: LogseqOutlineRow]
    ) -> some View {
        Group {
            Text(verbatim: section.title)
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal, 8)
                .padding(.top, 26)
                .padding(.bottom, 12)
            ForEach(section.blocks.compactMap { rowsByID[$0.uuid] }) { row in
                blockRow(row)
            }
        }
    }

    private func blockRow(_ row: LogseqOutlineRow) -> some View {
        OutlinerBlockRow(
            row: row,
            statuses: statuses,
            renderKey: OutlinerRowRenderKey(
                row: row,
                statuses: statuses,
                isEditing: editing?.uuid == row.block.uuid,
                isSelected: selectedBlockIDs.contains(row.block.uuid),
                isSelectionActive: !selectedBlockIDs.isEmpty,
                editingTitle: editing?.uuid == row.block.uuid
                    ? editing?.title ?? row.block.title : row.block.title,
                desiredCaretUTF16Offset: editing?.uuid == row.block.uuid
                    ? editing?.caretUTF16Offset : nil
            ),
            isEditing: editing?.uuid == row.block.uuid,
            isSelected: selectedBlockIDs.contains(row.block.uuid),
            isSelectionActive: !selectedBlockIDs.isEmpty,
            editingTitle: editing?.uuid == row.block.uuid
                ? editing?.title ?? row.block.title : row.block.title,
            onZoom: {
                onZoomBlock(row.block.uuid)
            },
            onToggleCollapse: {
                sendEvent(LogseqOutlinerEvent(type: "toggleCollapsed", uuid: row.block.uuid))
            },
            onEdit: {
                onBeginInteraction()
                sendEvent(LogseqOutlinerEvent(type: "tapBlock", uuid: row.block.uuid))
            },
            onLongPress: {
                onBeginInteraction()
                sendEvent(LogseqOutlinerEvent(type: "longPressBlock", uuid: row.block.uuid))
            },
            onTextChange: { title, caret in
                sendEvent(LogseqOutlinerEvent(
                    type: "textChanged",
                    title: title,
                    caretUTF16Offset: caret
                ))
            },
            onReturnAtCaret: { title, caret in
                sendEvent(LogseqOutlinerEvent(
                    type: "returnPressed",
                    title: title,
                    caretUTF16Offset: caret
                ))
            },
            onBackspace: { title, selectionLength in
                sendEvent(LogseqOutlinerEvent(
                    type: "backspacePressed",
                    title: title,
                    selectionLength: selectionLength
                ))
            },
            desiredCaretUTF16Offset: editing?.uuid == row.block.uuid
                ? editing?.caretUTF16Offset : nil,
            onCaretChange: { offset in
                sendEvent(LogseqOutlinerEvent(
                    type: "caretMoved",
                    caretUTF16Offset: offset
                ))
            },
            onStatusChange: { status in
                sendEvent(LogseqOutlinerEvent(
                    type: "setTaskStatus",
                    uuid: row.block.uuid,
                    statusIdent: status.ident,
                    statusUuid: status.uuid
                ))
            },
            onDragStarted: { beginDrag(row.block) },
            onDrop: { placement in
                sendEvent(LogseqOutlinerEvent(
                    type: "dropBlocks",
                    targetUuid: row.block.uuid,
                    placement: placement.eventValue
                ))
                return true
            },
            onOpenMarkupLink: onOpenMarkupLink
        )
        .equatable()
    }

    private func beginDrag(_ block: LogseqBlock) {
        if !selectedBlockIDs.contains(block.uuid) {
            sendEvent(LogseqOutlinerEvent(type: "longPressBlock", uuid: block.uuid))
        }
    }

}

struct RelatedBlocksSection: View {
    let title: String
    let emptyTitle: String?
    let blocks: [LogseqBlock]
    let accessibilityIdentifier: String
    let onOpenMarkupLink: (OutlinerMarkupLink) -> Void

    var body: some View {
        Text(verbatim: title)
            .font(.title2.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .accessibilityIdentifier(accessibilityIdentifier)
        if blocks.isEmpty, let emptyTitle {
            Text(verbatim: emptyTitle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        ForEach(RelatedBlockGrouping.groups(blocks)) { group in
            if !group.breadcrumbs.isEmpty {
                BlockBreadcrumb(
                    summaries: group.breadcrumbs,
                    onOpenMarkupLink: onOpenMarkupLink
                )
                .padding(.top, 8)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(group.blocks) { block in
                    RelatedBlockRow(block: block, onOpenMarkupLink: onOpenMarkupLink)
                    if block.uuid != group.blocks.last?.uuid {
                        Divider()
                    }
                }
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

private struct BlockBreadcrumb: View {
    let summaries: [LogseqEntitySummary]
    let onOpenMarkupLink: (OutlinerMarkupLink) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(summaries.enumerated()), id: \.element.id) { index, summary in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button(summary.title) {
                    onOpenMarkupLink(.node(uuid: summary.uuid))
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("breadcrumb.related-blocks")
    }
}

private struct RelatedBlockRow: View {
    let block: LogseqBlock
    let onOpenMarkupLink: (OutlinerMarkupLink) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 5) {
                #if !SKIP
                Text(OutlinerMarkupAttributedString.make(
                    nodes: block.markup,
                    fallback: block.title.isEmpty ? "Untitled block" : block.title
                ))
                .environment(\.openURL, OpenURLAction { url in
                    guard let link = OutlinerMarkupLink(url: url) else { return .systemAction }
                    onOpenMarkupLink(link)
                    return .handled
                })
                #else
                Text(verbatim: block.title.isEmpty ? "Untitled block" : block.title)
                #endif
                BlockTrailingTags(
                    tags: BlockTagPresentationPolicy.trailingTags(
                        tags: block.tags,
                        markup: block.markup
                    ),
                    onOpenTag: { onOpenMarkupLink(.node(uuid: $0)) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        #if DEBUG
        .onAppear {
            print(
                "LogseqChat debug: related block uuid=\(block.uuid) "
                    + "markup=\(block.markup.count) refs=\(block.references.count) "
                    + "tags=\(block.tags.count) breadcrumbs=\(block.breadcrumbs.count)"
            )
        }
        #endif
    }
}

struct OutlinerBlockRow: View, Equatable {
    let row: LogseqOutlineRow
    let statuses: [LogseqTaskStatus]
    nonisolated let renderKey: OutlinerRowRenderKey
    let isEditing: Bool
    let isSelected: Bool
    let isSelectionActive: Bool
    let editingTitle: String
    let onZoom: () -> Void
    let onToggleCollapse: () -> Void
    let onEdit: () -> Void
    let onLongPress: () -> Void
    let onTextChange: (String, Int) -> Void
    let onReturnAtCaret: (String, Int) -> Void
    let onBackspace: (String, Int) -> Void
    let desiredCaretUTF16Offset: Int?
    let onCaretChange: (Int) -> Void
    let onStatusChange: (LogseqTaskStatus) -> Void
    let onDragStarted: () -> Void
    let onDrop: (OutlinerDropPlacement) -> Bool
    let onOpenMarkupLink: (OutlinerMarkupLink) -> Void
    @State private var measuredHeight: CGFloat = 44

    nonisolated static func == (left: Self, right: Self) -> Bool {
        left.renderKey == right.renderKey
    }

    private var isCompleted: Bool {
        let ident = row.block.status?.ident ?? ""
        return ident.hasSuffix(".done") || ident.hasSuffix(".canceled")
    }

    var body: some View {
        #if !SKIP && os(iOS)
        rowContent
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: OutlinerRowHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            }
            .onPreferenceChange(OutlinerRowHeightPreferenceKey.self) { measuredHeight = $0 }
            .onDrag {
                onDragStarted()
                return NSItemProvider(object: row.block.uuid as NSString)
            }
            .onDrop(
                of: [UTType.plainText],
                delegate: OutlinerRowDropDelegate(
                    rowHeight: measuredHeight,
                    onDrop: onDrop
                )
            )
        #else
        rowContent
        #endif
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 0) {
            depthSpacer
            bulletButton
            HStack(alignment: .top, spacing: 7) {
                statusMenu
                blockContent
                collapseButton
            }
            .padding(.leading, 7)
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
            depthGuides
                .allowsHitTesting(false)
        }
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .platformOutlinerAccessibilityContainer()
        .accessibilityIdentifier("outliner.block.\(row.block.uuid)")
    }

    private var depthSpacer: some View {
        Color.clear
            .frame(width: CGFloat(row.depth) * OutlinerLayoutMetrics.indentation, height: 24)
    }

    private var depthGuides: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<row.depth, id: \.self) { level in
                Rectangle()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .offset(x: OutlinerLayoutMetrics.guideCenterX(level: level) - 0.5)
            }
            if row.hasChildren && !row.isCollapsed {
                Rectangle()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .padding(.top, 17)
                    .offset(x: OutlinerLayoutMetrics.bulletCenterX(depth: row.depth) - 0.5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var bulletButton: some View {
        ZStack {
            Color.clear
            Circle()
                .fill(Color.secondary.opacity(0.38))
                .frame(width: 7, height: 7)
        }
        .frame(
            width: OutlinerLayoutMetrics.bulletHitSize,
            height: OutlinerLayoutMetrics.bulletHitSize
        )
        .platformOutlinerFullRowHitTarget()
        .onTapGesture(perform: onZoom)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(OutlinerAccessibilityTitle.zoom(blockTitle: row.block.title))
        .accessibilityIdentifier("button.outliner.zoom.\(row.block.uuid)")
    }

    @ViewBuilder private var statusMenu: some View {
        if let status = row.block.status {
            Menu {
                ForEach(statuses) { option in
                    Button {
                        onStatusChange(option)
                    } label: {
                        HStack {
                            TaskStatusIcon(status: option)
                            Text(verbatim: option.title)
                        }
                    }
                    .accessibilityIdentifier(
                        "button.block-task-status-option.\(option.ident ?? option.uuid)"
                    )
                }
            } label: {
                TaskStatusIcon(status: status, size: 22)
                    .frame(width: 22, height: 22)
            }
            .platformIconMenuStyle()
            .accessibilityIdentifier("button.block-task-status")
        }
    }

    private var blockContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isEditing {
                #if !SKIP && os(iOS)
                Text(verbatim: editingTitle.isEmpty ? " " : editingTitle)
                    .font(.body)
                    .foregroundStyle(.clear)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .topLeading)
                    .accessibilityHidden(true)
                    .anchorPreference(
                        key: OutlinerEditorAnchorPreferenceKey.self,
                        value: .bounds
                    ) { [row.block.uuid: $0] }
                #else
                OutlinerInlineEditor(
                    text: editingTitle,
                    blockID: row.block.uuid,
                    desiredCaretUTF16Offset: desiredCaretUTF16Offset,
                    onTextChange: onTextChange,
                    onReturn: onReturnAtCaret,
                    onBackspace: onBackspace,
                    onCaretChange: onCaretChange
                )
                #endif
            } else {
                renderedTitle
                    .font(.body)
                    .strikethrough(isCompleted)
                    .foregroundStyle(isCompleted ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                BlockTrailingTags(
                    tags: BlockTagPresentationPolicy.trailingTags(
                        tags: row.block.tags,
                        markup: row.block.markup
                    ),
                    onOpenTag: { onOpenMarkupLink(.node(uuid: $0)) }
                )
            }
            syncStatus
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .platformOutlinerFullRowHitTarget()
        .onTapGesture {
            if !isEditing {
                onEdit()
            }
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            onLongPress()
        }
        .platformOutlinerEditAccessibility(
            title: row.block.title.isEmpty ? "Untitled block" : row.block.title,
            isEditing: isEditing,
            isSelectionActive: isSelectionActive,
            onEdit: onEdit
        )
    }

    @ViewBuilder private var renderedTitle: some View {
        #if !SKIP
        Text(OutlinerMarkupAttributedString.make(
            nodes: row.block.markup,
            fallback: row.block.title.isEmpty ? "Untitled block" : row.block.title
        ))
        .environment(\.openURL, OpenURLAction { url in
            guard let link = OutlinerMarkupLink(url: url) else { return .systemAction }
            onOpenMarkupLink(link)
            return .handled
        })
        #else
        Text(verbatim: row.block.title.isEmpty ? "Untitled block" : row.block.title)
        #endif
    }

    @ViewBuilder private var syncStatus: some View {
        if row.block.isPendingSync || row.block.syncStatus == "submitted" {
            Text(verbatim: "Pending")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if row.block.isFailedSync {
            Text(verbatim: "Sync failed")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder private var collapseButton: some View {
        if row.hasChildren {
            Button {
                onToggleCollapse()
            } label: {
                DisclosureGlyph(collapsed: row.isCollapsed)
                    .fill(Color.secondary)
                    .frame(width: 8, height: 8)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(OutlinerAccessibilityTitle.collapse(
                blockTitle: row.block.title,
                isCollapsed: row.isCollapsed
            ))
            .accessibilityIdentifier("button.outliner.collapse.\(row.block.uuid)")
        }
    }
}

#if !SKIP
enum OutlinerMarkupAttributedString {
    static func make(nodes: [LogseqMarkupNode], fallback: String) -> AttributedString {
        guard !nodes.isEmpty else { return AttributedString(fallback) }
        var result = AttributedString()
        for node in nodes {
            result.append(make(node))
        }
        return result
    }

    private static func make(_ node: LogseqMarkupNode) -> AttributedString {
        switch node.type {
        case .text:
            return AttributedString(node.text ?? "")
        case .code:
            var value = AttributedString(node.text ?? "")
            value.font = .system(.body, design: .monospaced)
            value.backgroundColor = Color.secondary.opacity(0.12)
            return value
        case .emphasis:
            var value = make(nodes: node.children, fallback: "")
            switch node.style {
            case "bold": value.font = .body.bold()
            case "italic": value.font = .body.italic()
            case "underline": value.underlineStyle = .single
            case "strikeThrough": value.strikethroughStyle = .single
            case "highlight": value.backgroundColor = Color.yellow.opacity(0.25)
            default: break
            }
            return value
        case .link:
            var value = make(nodes: node.children, fallback: node.url ?? "")
            value.link = node.url.flatMap(URL.init(string:))
            return value
        case .nodeReference:
            var value = AttributedString(node.title ?? "")
            if let uuid = node.uuid {
                value.link = OutlinerMarkupLink.node(uuid: uuid).url
            }
            return value
        case .tagReference:
            var value = AttributedString("#" + (node.title ?? ""))
            if let uuid = node.uuid {
                value.link = OutlinerMarkupLink.node(uuid: uuid).url
            }
            return value
        }
    }
}
#endif

struct BlockTrailingTags: View {
    let tags: [LogseqEntitySummary]
    let onOpenTag: (String) -> Void

    @ViewBuilder var body: some View {
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tags) { tag in
                        Button {
                            onOpenTag(tag.uuid)
                        } label: {
                            Text(verbatim: "#" + tag.title)
                                .font(.caption)
                                .foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open tag " + tag.title)
                        .accessibilityIdentifier("button.block-tag.\(tag.uuid)")
                    }
                }
            }
        }
    }
}

#if !SKIP && os(iOS)
private struct OutlinerEditorAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [String: Anchor<CGRect>],
        nextValue: () -> [String: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
#endif

private extension View {
    @ViewBuilder func platformOutlinerAccessibilityContainer() -> some View {
        #if !SKIP
        accessibilityElement(children: .contain)
        #else
        self
        #endif
    }

    @ViewBuilder func platformOutlinerFullRowHitTarget() -> some View {
        #if !SKIP
        contentShape(Rectangle())
        #else
        self
        #endif
    }

    @ViewBuilder func platformOutlinerEditAccessibility(
        title: String,
        isEditing: Bool,
        isSelectionActive: Bool,
        onEdit: @escaping () -> Void
    ) -> some View {
        #if !SKIP
        accessibilityElement(children: .contain)
            .accessibilityLabel((isSelectionActive ? "Select block " : "Edit block ") + title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if !isEditing {
                    onEdit()
                }
            }
        #else
        self
        #endif
    }
}

struct OutlinerAutocompleteBar: View {
    let candidates: [LogseqOutlinerAutocompleteCandidate]
    let onSelect: (LogseqOutlinerAutocompleteCandidate) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                    Button(candidate.label) {
                        onSelect(candidate)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
                    .accessibilityIdentifier("button.outliner.autocomplete.\(index)")
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 38)
        .accessibilityIdentifier("toolbar.outliner.autocomplete")
    }
}

#if !SKIP && os(iOS)
private struct OutlinerRowHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 44

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct OutlinerRowDropDelegate: DropDelegate {
    let rowHeight: CGFloat
    let onDrop: (OutlinerDropPlacement) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText])
    }

    func performDrop(info: DropInfo) -> Bool {
        onDrop(OutlinerDropZone.placement(
            locationY: info.location.y,
            rowHeight: rowHeight
        ))
    }
}
#endif

#if !SKIP
struct OutlinerEditorToolbar: View {
    let onAction: (OutlinerToolbarAction) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(OutlinerToolbarPolicy.editorActions, id: \.self) { action in
                        toolbarButton(action)
                    }
                }
                .padding(.leading, 8)
            }
            toolbarButton(OutlinerToolbarPolicy.trailingEditorAction)
                .padding(.horizontal, 6)
                .accessibilityIdentifier("button.outliner.editor.hideKeyboard")
        }
        .frame(height: 50)
        .accessibilityIdentifier("toolbar.outliner.editor")
    }

    private func toolbarButton(_ action: OutlinerToolbarAction) -> some View {
        Button {
            onAction(action)
        } label: {
            Image(systemName: action.systemImageName)
                .font(.system(size: OutlinerToolbarPolicy.iconSize, weight: .medium))
                .frame(
                    width: OutlinerToolbarPolicy.iconBoxSize,
                    height: OutlinerToolbarPolicy.iconBoxSize
                )
                .frame(width: OutlinerToolbarPolicy.editorItemWidth, height: 42)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.accessibilityTitle)
        .accessibilityIdentifier("button.outliner.editor.\(action.identifier)")
    }
}

struct OutlinerSelectionToolbar: View {
    let onAction: (OutlinerToolbarAction) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OutlinerToolbarPolicy.selectionItemSpacing) {
                ForEach(OutlinerToolbarPolicy.selectionActions, id: \.self) { action in
                    Button {
                        onAction(action)
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: action.systemImageName)
                                .font(.system(size: OutlinerToolbarPolicy.iconSize, weight: .medium))
                                .frame(
                                    width: OutlinerToolbarPolicy.iconBoxSize,
                                    height: OutlinerToolbarPolicy.iconBoxSize
                                )
                            Text(action.accessibilityTitle)
                                .font(.caption2)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(height: OutlinerToolbarPolicy.captionHeight)
                        }
                        .frame(
                            width: OutlinerToolbarPolicy.selectionItemWidth,
                            height: 46,
                            alignment: .center
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(action.accessibilityTitle)
                    .accessibilityIdentifier("button.outliner.selection.\(action.identifier)")
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 54)
        .accessibilityIdentifier("toolbar.outliner.selection")
    }
}
#endif

private struct DisclosureGlyph: Shape {
    let collapsed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if collapsed {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

private extension OutlinerToolbarAction {
    var identifier: String {
        String(describing: self)
    }

}

struct ErrorBanner: View {
    let error: LogseqChatCoreError

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: error.code)
                .font(.headline)
            Text(verbatim: error.message)
                .font(.subheadline)
        }
        .foregroundStyle(Color(red: 0.48, green: 0.08, blue: 0.08))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(red: 1.0, green: 0.90, blue: 0.90))
        .cornerRadius(16)
    }
}

struct EmptyBlocksView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "No cached blocks")
                .font(.headline)
            Text(verbatim: "Connect to Logseq or add a local block to start.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white.opacity(0.65))
        .cornerRadius(18)
    }
}
