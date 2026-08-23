import SwiftUI
import LogseqChatModel
#if !SKIP && os(iOS)
import UIKit
import UniformTypeIdentifiers
#endif

enum OutlinerBlockPresentationPolicy {
    static func usesAssetPreview(isAsset: Bool) -> Bool {
        isAsset
    }
}

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
    let relatedEmptyTitle: String?
    let relatedBlocks: [LogseqBlock]
    let relatedAccessibilityIdentifier: String
    let linkedReferenceBlocks: [LogseqBlock]
    let showsEmptyPlaceholder: Bool
    let onAddFirstBlock: (() -> Void)?
    let isJournalHome: Bool
    var body: some View {
        GeometryReader { proxy in
            outlinerContent(viewportHeight: proxy.size.height)
        }
    }

    @ViewBuilder private func outlinerContent(viewportHeight: CGFloat) -> some View {
        let rowsByID = rowIndex(rows)
        let visibleSections = sections.filter { section in
            section.blocks.contains(where: { rowsByID[$0.uuid] != nil })
        }
        let scrollContent = ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: topPadding)
                if let error {
                    ErrorBanner(error: error)
                        .padding(.bottom, 12)
                }
                if rows.isEmpty {
                    if let onAddFirstBlock {
                        AddFirstBlockButton(action: onAddFirstBlock)
                    } else if showsEmptyPlaceholder {
                        EmptyBlocksView()
                    }
                } else {
                    ForEach(Array(visibleSections.enumerated()), id: \.element.id) { index, section in
                        LazyVStack(alignment: .leading, spacing: 0) {
                            sectionView(section, rowsByID: rowsByID)
                        }
                        .frame(
                            minHeight: isJournalHome
                                ? max(0.0, viewportHeight - topPadding - bottomPadding)
                                : 0.0,
                            alignment: .top
                        )
                        if isJournalHome, index < visibleSections.count - 1 {
                            Divider()
                                .accessibilityIdentifier("journal.divider")
                        }
                    }
                }
                if hasOlderJournals {
                    Color.clear
                        .frame(height: 1)
                        .onAppear(perform: onLoadOlderJournals)
                        .accessibilityHidden(true)
                }
                if let relatedTitle {
                    relatedSection(
                        title: relatedTitle,
                        emptyTitle: relatedEmptyTitle,
                        blocks: relatedBlocks,
                        accessibilityIdentifier: relatedAccessibilityIdentifier
                    )
                }
                if !linkedReferenceBlocks.isEmpty {
                    relatedSection(
                        title: "Linked references",
                        emptyTitle: nil,
                        blocks: linkedReferenceBlocks,
                        accessibilityIdentifier: "section.node.linked-references"
                    )
                }
                Color.clear.frame(height: bottomPadding)
            }
            .padding(.horizontal, OutlinerLayoutMetrics.outerHorizontalInset)
        }
        .accessibilityIdentifier("list.outliner")
        #if !SKIP && os(iOS)
        let content = ScrollViewReader { proxy in
            scrollContent
                .onChange(of: editing?.uuid) { previousID, currentID in
                    if OutlinerEditorViewportPolicy.shouldEnsureVisible(
                        previousBlockID: previousID,
                        blockID: currentID,
                        viewportChanged: false
                    ), let currentID {
                        ensureEditorVisible(currentID, proxy: proxy)
                    }
                }
                .onChange(of: viewportHeight) { previousHeight, currentHeight in
                    guard abs(previousHeight - currentHeight) >= 1 else { return }
                    if OutlinerEditorViewportPolicy.shouldEnsureVisible(
                        previousBlockID: editing?.uuid,
                        blockID: editing?.uuid,
                        viewportChanged: true
                    ), let editing {
                        ensureEditorVisible(editing.uuid, proxy: proxy)
                    }
                }
        }
        content
        #else
        scrollContent
        #endif
    }

    #if !SKIP && os(iOS)
    private func ensureEditorVisible(_ blockID: String, proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(blockID, anchor: .center)
        }
    }
    #endif

    private func rowIndex(_ rows: [LogseqOutlineRow]) -> [String: LogseqOutlineRow] {
        var result: [String: LogseqOutlineRow] = [:]
        for row in rows where result[row.block.uuid] == nil {
            result[row.block.uuid] = row
        }
        return result
    }

    private func sectionView(
        _ section: LogseqBlockSection,
        rowsByID: [String: LogseqOutlineRow]
    ) -> some View {
        Group {
            sectionTitle(section)
            ForEach(section.blocks.compactMap { rowsByID[$0.uuid] }) { row in
                blockRow(row)
            }
        }
    }

    @ViewBuilder private func sectionTitle(_ section: LogseqBlockSection) -> some View {
        let pageUUID = OutlinerSectionNavigationPolicy.pageUUID(
            isJournalHome: isJournalHome,
            sectionBlockPageIDs: section.blocks.map(\.pageId)
        )
        if let pageUUID {
            Button {
                onZoomBlock(pageUUID)
            } label: {
                journalSectionTitle(section.title)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(section.title)")
            .accessibilityIdentifier("button.journal.\(pageUUID)")
        } else {
            journalSectionTitle(section.title)
        }
    }

    private func journalSectionTitle(_ title: String) -> some View {
        Text(verbatim: title)
            .font(.title2)
            .fontWeight(.bold)
            .padding(.horizontal, 8)
            .padding(.top, 26)
            .padding(.bottom, 12)
    }

    // Tagged nodes and linked references reuse the outliner block row so they
    // stay editable in place; rows that stand for whole pages navigate instead
    // of opening the inline editor.
    @ViewBuilder private func relatedSection(
        title: String,
        emptyTitle: String?,
        blocks: [LogseqBlock],
        accessibilityIdentifier: String
    ) -> some View {
        Text(verbatim: title)
            .font(.title2.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 26)
            .padding(.bottom, 8)
            .accessibilityIdentifier(accessibilityIdentifier)
        if blocks.isEmpty, let emptyTitle {
            Text(verbatim: emptyTitle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
        }
        ForEach(RelatedBlockGrouping.groups(blocks)) { group in
            if !group.breadcrumbs.isEmpty {
                BlockBreadcrumb(
                    summaries: group.breadcrumbs,
                    onOpenMarkupLink: onOpenMarkupLink
                )
                .padding(.top, 10)
                .padding(.horizontal, 8)
            }
            ForEach(group.blocks) { block in
                blockRow(
                    relatedRow(block),
                    opensAsPage: block.uuid == block.pageId
                )
            }
        }
    }

    private func relatedRow(_ block: LogseqBlock) -> LogseqOutlineRow {
        LogseqOutlineRow(block: block, depth: 0, hasChildren: false, isCollapsed: false)
    }

    private func blockRow(_ row: LogseqOutlineRow, opensAsPage: Bool = false) -> some View {
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
                if opensAsPage {
                    onZoomBlock(row.block.uuid)
                } else {
                    onBeginInteraction()
                    sendEvent(LogseqOutlinerEvent(type: "tapBlock", uuid: row.block.uuid))
                }
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
                    uuid: row.block.uuid,
                    title: title,
                    caretUTF16Offset: caret
                ))
            },
            onBackspace: { title, selectionLength in
                sendEvent(LogseqOutlinerEvent(
                    type: "backspacePressed",
                    uuid: row.block.uuid,
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
        .id(row.block.uuid)
    }

    private func beginDrag(_ block: LogseqBlock) {
        if !selectedBlockIDs.contains(block.uuid) {
            sendEvent(LogseqOutlinerEvent(type: "longPressBlock", uuid: block.uuid))
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
                        .foregroundStyle(.secondary)
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

    private var usesAssetPreview: Bool {
        OutlinerBlockPresentationPolicy.usesAssetPreview(isAsset: row.block.isAsset)
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
            .padding(.leading, OutlinerLayoutMetrics.bulletContentSpacing)
        }
        .padding(.vertical, OutlinerLayoutMetrics.rowVerticalPadding)
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
            .frame(
                width: CGFloat(row.depth) * OutlinerLayoutMetrics.indentation,
                height: OutlinerLayoutMetrics.depthSpacerHeight
            )
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
        .onTapGesture {
            onZoom()
        }
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
                OutlinerInlineEditor(
                    text: editingTitle,
                    blockID: row.block.uuid,
                    desiredCaretUTF16Offset: desiredCaretUTF16Offset,
                    onTextChange: onTextChange,
                    onReturn: onReturnAtCaret,
                    onBackspace: onBackspace,
                    onCaretChange: onCaretChange
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: OutlinerLayoutMetrics.titleLineHeight,
                    alignment: .leading
                )
            } else {
                if usesAssetPreview {
                    AssetPreview(block: row.block, onOpen: nil)
                } else {
                    renderedTitle
                        .font(.body)
                        .strikethrough(isCompleted)
                        .foregroundStyle(isCompleted ? .secondary : .primary)
                        .frame(
                            minHeight: OutlinerLayoutMetrics.titleLineHeight,
                            alignment: .leading
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            BlockTrailingTags(
                tags: BlockTagPresentationPolicy.trailingTags(
                    tags: row.block.tags,
                    markup: row.block.markup
                ),
                onOpenTag: { onOpenMarkupLink(.node(uuid: $0)) }
            )
            syncStatus
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .platformOutlinerFullRowHitTarget()
        .outlinerTapToEdit(
            isEnabled: !isEditing
                && !OutlinerRichMarkupPolicy.containsInteractive(row.block.markup),
            onEdit: onEdit
        )
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
        // An empty block renders as a blank line (a space keeps the row
        // height and tap target); accessibility still says "Untitled block".
        if OutlinerRichMarkupPolicy.containsRich(row.block.markup) {
            OutlinerMixedRichMarkupContent(
                nodes: row.block.markup,
                fallback: row.block.title.isEmpty ? " " : row.block.title,
                onOpenMarkupLink: onOpenMarkupLink
            )
        } else {
            #if !SKIP
            Text(OutlinerMarkupAttributedString.make(
                nodes: row.block.markup,
                fallback: row.block.title.isEmpty ? " " : row.block.title
            ))
            .environment(\.openURL, OpenURLAction { url in
                guard let link = OutlinerMarkupLink(url: url) else { return .systemAction }
                onOpenMarkupLink(link)
                return .handled
            })
            #else
            Text(verbatim: row.block.title.isEmpty ? " " : row.block.title)
            #endif
        }
    }

    @ViewBuilder private var syncStatus: some View {
        if row.block.isFailedSync {
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

private struct OutlinerMixedRichMarkupContent: View {
    let nodes: [LogseqMarkupNode]
    let fallback: String
    let onOpenMarkupLink: (OutlinerMarkupLink) -> Void

    private var chunks: [[LogseqMarkupNode]] {
        OutlinerRichMarkupPolicy.chunks(nodes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<chunks.count, id: \.self) { index in
                let chunk = chunks[index]
                if chunk.count == 1,
                   let node = chunk.first,
                   OutlinerRichMarkupPolicy.isRich(node.type) {
                    OutlinerRichBlockContent(
                        node: node,
                        onOpenMarkupLink: onOpenMarkupLink
                    )
                } else {
                    inlineContent(chunk)
                        .accessibilityIdentifier("block.rich.inline.\(index)")
                }
            }
        }
    }

    @ViewBuilder private func inlineContent(_ chunk: [LogseqMarkupNode]) -> some View {
        #if !SKIP
        Text(OutlinerMarkupAttributedString.make(nodes: chunk, fallback: fallback))
            .environment(\.openURL, OpenURLAction { url in
                guard let link = OutlinerMarkupLink(url: url) else { return .systemAction }
                onOpenMarkupLink(link)
                return .handled
            })
        #else
        let presentation = OutlinerMarkupPresentation.make(nodes: chunk, fallback: fallback)
        Text(verbatim: presentation.plainText)
        #endif
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
        case .codeBlock, .math, .cloze:
            return AttributedString(node.text ?? "")
        case .youtubeTimestamp:
            return AttributedString("◷ " + (node.text ?? ""))
        case .emphasis, .quote:
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
        case .video, .iframe:
            return AttributedString(node.url ?? "")
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

private extension View {
    @ViewBuilder func outlinerTapToEdit(
        isEnabled: Bool,
        onEdit: @escaping () -> Void
    ) -> some View {
        if isEnabled {
            onTapGesture { onEdit() }
        } else {
            self
        }
    }

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
        ScrollView(
            .vertical,
            showsIndicators: OutlinerAutocompleteLayoutPolicy.height(
                candidateCount: candidates.count
            ) >= OutlinerAutocompleteLayoutPolicy.maximumHeight
        ) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                    Button {
                        onSelect(candidate)
                    } label: {
                        HStack {
                            Text(verbatim: candidate.label)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("button.outliner.autocomplete.\(index)")
                }
            }
            .padding(8)
        }
        .frame(height: OutlinerAutocompleteLayoutPolicy.height(candidateCount: candidates.count))
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
            Group {
                if action == .pageReference {
                    Text(verbatim: "[[]]")
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                } else {
                    Image(systemName: action.systemImageName)
                        .font(.system(size: OutlinerToolbarPolicy.iconSize, weight: .medium))
                }
            }
                .frame(
                    width: action == .pageReference
                        ? 36 : OutlinerToolbarPolicy.iconBoxSize,
                    height: OutlinerToolbarPolicy.iconBoxSize
                )
                .frame(width: OutlinerToolbarPolicy.editorItemWidth, height: 42)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.accessibilityTitle)
        .accessibilityValue(action == .pageReference ? "[[]]" : "")
        .accessibilityIdentifier("button.outliner.editor.\(action.identifier)")
    }
}

struct OutlinerSelectionToolbar: View {
    let onAction: (OutlinerToolbarAction) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: OutlinerToolbarPolicy.selectionItemSpacing) {
                    ForEach(OutlinerToolbarPolicy.selectionActions, id: \.self) { action in
                        selectionButton(action)
                    }
                }
                .padding(.leading, 12)
            }
            selectionButton(OutlinerToolbarPolicy.trailingSelectionAction)
                .padding(.horizontal, 6)
        }
        .frame(height: 54)
        .accessibilityIdentifier("toolbar.outliner.selection")
    }

    private func selectionButton(_ action: OutlinerToolbarAction) -> some View {
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

struct AddFirstBlockButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                Text(verbatim: "Add a block")
                    .font(.body.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a block")
        .accessibilityIdentifier("button.outliner.add-first-block")
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
