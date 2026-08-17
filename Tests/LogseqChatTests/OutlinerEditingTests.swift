import CoreGraphics
import Foundation
import LogseqChatModel
import Testing
@testable import LogseqChat

@Suite struct OutlinerEditingTests {
    @Test func chatAndOutlinerUseDifferentEditorSurfaces() {
        #expect(BlockEditingPolicy.presentation(for: LogseqContentMode.chat) == BlockEditPresentation.composer)
        #expect(BlockEditingPolicy.presentation(for: LogseqContentMode.outliner) == BlockEditPresentation.inline)
    }

    @Test func blockSelectionStartsWithLongPress() {
        #expect(BlockSelectionGesturePolicy.activation == .longPress)
    }

    @Test func copiedNodeReferencesUseTheDbGraphBracketSyntax() {
        #expect(OutlinerClipboardPolicy.nodeReferences(["page-uuid", "block-uuid"]) ==
            "[[page-uuid]]\n[[block-uuid]]")
        #expect(OutlinerClipboardPolicy.nodeReferences([]).isEmpty)
    }

    @Test func typedMarkupLinksUseOneNodeRouteForPagesAndBlocks() throws {
        let pageURL = try #require(OutlinerMarkupLink.node(uuid: "page-uuid").url)
        let blockURL = try #require(OutlinerMarkupLink.node(uuid: "block-uuid").url)
        let tagURL = try #require(OutlinerMarkupLink.node(uuid: "tag-uuid").url)

        #expect(OutlinerMarkupLink(url: pageURL) == .node(uuid: "page-uuid"))
        #expect(OutlinerMarkupLink(url: blockURL) == .node(uuid: "block-uuid"))
        #expect(OutlinerMarkupLink(url: tagURL) == .node(uuid: "tag-uuid"))
        #expect(OutlinerMarkupLink(url: URL(string: "logseq-tag://tag-uuid")!) == nil)
        #expect(OutlinerMarkupLink(url: URL(string: "https://logseq.com")!) == nil)
    }

    @Test func typedMarkupLinksRejectIncompleteOrUnsupportedRoutes() throws {
        #expect(OutlinerMarkupLink(url: try #require(URL(string: "logseq-node:?kind=page"))) == nil)
        #expect(OutlinerMarkupLink(url: try #require(URL(string: "logseq-node://node"))) == .node(uuid: "node"))
        #expect(OutlinerMarkupLink(url: try #require(
            URL(string: "logseq-node://node?kind=object")
        )) == .node(uuid: "node"))
    }

    @Test func typedMarkupPresentationPreservesTextAndLinkDestinations() throws {
        let nodes = [
            LogseqMarkupNode(type: .text, text: "See "),
            LogseqMarkupNode(
                type: .nodeReference, uuid: "page-uuid", title: "Page"
            ),
            LogseqMarkupNode(type: .text, text: " and "),
            LogseqMarkupNode(type: .tagReference, uuid: "tag-uuid", title: "Project"),
        ]
        let presentation = OutlinerMarkupPresentation.make(nodes: nodes, fallback: "fallback")

        #expect(presentation.plainText == "See Page and #Project")
        #expect(presentation.links == [
            OutlinerMarkupLink.node(uuid: "page-uuid"),
            OutlinerMarkupLink.node(uuid: "tag-uuid"),
        ])
        #expect(OutlinerMarkupPresentation.make(nodes: [], fallback: "((legacy))").plainText ==
            "((legacy))")
    }

    @Test func typedMarkupPresentationCoversNestedAndIncompleteMldocNodes() {
        let nodes = [
            LogseqMarkupNode(type: .text),
            LogseqMarkupNode(
                type: .emphasis,
                children: [LogseqMarkupNode(type: .code, text: "nested")]
            ),
            LogseqMarkupNode(type: .link),
            LogseqMarkupNode(type: .link, url: "https://logseq.com"),
            LogseqMarkupNode(
                type: .link,
                children: [LogseqMarkupNode(type: .text, text: "label")]
            ),
            LogseqMarkupNode(type: .nodeReference),
            LogseqMarkupNode(type: .tagReference),
        ]

        let presentation = OutlinerMarkupPresentation.make(nodes: nodes, fallback: "unused")
        #expect(presentation.plainText == "nestedhttps://logseq.comlabel#")
        #expect(presentation.links.isEmpty)
    }

    @Test func inlineTagsStayInContentAndOnlyNonInlineTagsTrailTheBlock() throws {
        let summaries = try JSONDecoder().decode(
            [LogseqEntitySummary].self,
            from: Data("""
            [
              {"uuid":"inline","title":"Inline"},
              {"uuid":"trailing","title":"Trailing"}
            ]
            """.utf8)
        )
        let inline = summaries[0]
        let trailing = summaries[1]
        let markup = [
            LogseqMarkupNode(
                type: .emphasis,
                children: [
                    LogseqMarkupNode(type: .tagReference, uuid: "inline", title: "Inline"),
                    LogseqMarkupNode(type: .tagReference, uuid: "inline", title: "Inline"),
                    LogseqMarkupNode(type: .tagReference, title: "Incomplete")
                ]
            )
        ]

        #expect(BlockTagPresentationPolicy.inlineTagIDs(markup) == Set(["inline"]))
        #expect(BlockTagPresentationPolicy.trailingTags(
            tags: [inline, trailing, trailing],
            markup: markup
        ) == [trailing])
        #expect(BlockTagPresentationPolicy.trailingTags(tags: [], markup: []).isEmpty)
    }

    @Test func toolbarDoesNotExposeUndoOrRedoYet() {
        #expect(!OutlinerToolbarPolicy.editorActions.contains(OutlinerToolbarAction.undo))
        #expect(!OutlinerToolbarPolicy.editorActions.contains(OutlinerToolbarAction.redo))
        #expect(!OutlinerToolbarPolicy.selectionActions.contains(OutlinerToolbarAction.undo))
        #expect(!OutlinerToolbarPolicy.selectionActions.contains(OutlinerToolbarAction.redo))
        #expect(OutlinerToolbarAction.undo.eventValue == nil)
        #expect(OutlinerToolbarAction.redo.eventValue == nil)
        #expect(OutlinerToolbarAction.undo.systemImageName == "arrow.uturn.backward")
        #expect(OutlinerToolbarAction.redo.systemImageName == "arrow.uturn.forward")
        #expect(OutlinerToolbarAction.undo.accessibilityTitle == "Undo")
        #expect(OutlinerToolbarAction.redo.accessibilityTitle == "Redo")
    }

    @Test func editorToolbarMatchesCurrentLogseqMobileOrderAndSymbols() {
        let expected: [OutlinerToolbarAction] = [
            .task, .outdent, .indent, .tag, .camera, .attachment,
            .pageReference,
        ]
        #expect(OutlinerToolbarPolicy.editorActions == expected)
        #expect(OutlinerToolbarPolicy.trailingEditorAction == .hideKeyboard)
        #expect(OutlinerToolbarPolicy.editorActions.map(\.systemImageName) == [
            "checkmark.square", "arrow.left", "arrow.right", "number", "camera",
            "paperclip", "parentheses",
        ])
        #expect(OutlinerToolbarPolicy.trailingEditorAction.systemImageName == "keyboard.chevron.compact.down")
    }

    @Test func selectionToolbarMatchesCurrentLogseqMobileOrderAndSymbols() {
        let expected: [OutlinerToolbarAction] = [
            .copy, .outdent, .indent, .delete, .copyReference, .copyURL,
        ]
        #expect(OutlinerToolbarPolicy.selectionActions == expected)
        #expect(OutlinerToolbarPolicy.selectionActions.map(\.systemImageName) == [
            "doc.on.doc", "arrow.left", "arrow.right", "trash", "r.square", "link",
        ])
        #expect(OutlinerToolbarPolicy.trailingSelectionAction == .unselect)
        #expect(OutlinerToolbarPolicy.trailingSelectionAction.systemImageName == "xmark")
    }

    @Test func toolbarItemsStayCompactInsideHorizontalScrollViews() {
        #expect(OutlinerToolbarPolicy.editorItemWidth == 42)
        #expect(OutlinerToolbarPolicy.selectionItemWidth == 58)
        #expect(OutlinerToolbarPolicy.selectionItemSpacing == 6)
        #expect(OutlinerToolbarPolicy.iconSize == 18)
        #expect(OutlinerToolbarPolicy.iconBoxSize == 22)
        #expect(OutlinerToolbarPolicy.captionHeight == 14)
    }

    @Test func outlineDepthGridAlignsGuidesWithAncestorBullets() {
        #expect(OutlinerLayoutMetrics.outerHorizontalInset == 8)
        #expect(OutlinerLayoutMetrics.rootBulletCenterX == 12)
        #expect(OutlinerLayoutMetrics.bulletCenterX(depth: 0) == 12)
        #expect(OutlinerLayoutMetrics.bulletCenterX(depth: 1) == 34)
        #expect(OutlinerLayoutMetrics.guideCenterX(level: 0) == 12)
        #expect(OutlinerLayoutMetrics.guideCenterX(level: 1) == 34)
    }

    @Test func olderJournalPaginationIsExplicitAndAccessible() {
        #expect(OutlinerPaginationPolicy.buttonTitle == "Load earlier journals")
        #expect(OutlinerPaginationPolicy.accessibilityIdentifier == "button.outliner.load-older-journals")
    }

    @Test func outlineControlsNameTheirBlockForAccessibleNavigation() {
        #expect(OutlinerAccessibilityTitle.zoom(blockTitle: "Parent") == "Zoom into Parent")
        #expect(OutlinerAccessibilityTitle.collapse(
            blockTitle: "Parent", isCollapsed: false
        ) == "Collapse Parent")
        #expect(OutlinerAccessibilityTitle.collapse(
            blockTitle: "Parent", isCollapsed: true
        ) == "Expand Parent")
        #expect(OutlinerAccessibilityTitle.zoom(blockTitle: "") == "Zoom into Untitled block")
    }

    @Test func nativeOutlinerNavigationOnlyDispatchesMissingBackSteps() {
        #expect(OutlinerNavigationPolicy.backStepCount(
            presentedPath: ["parent"],
            modelPath: ["parent", "child"]
        ) == 1)
        #expect(OutlinerNavigationPolicy.backStepCount(
            presentedPath: [],
            modelPath: ["parent", "child"]
        ) == 2)
        #expect(OutlinerNavigationPolicy.backStepCount(
            presentedPath: ["parent", "child"],
            modelPath: ["parent", "child"]
        ) == 0)
        #expect(OutlinerNavigationPolicy.backStepCount(
            presentedPath: ["other"],
            modelPath: ["parent"]
        ) == 0)
    }

    @Test func nativeBackClosesExactlyOneCoreNodeProjection() {
        let previousPath: [AppNavigationRoute] = [.node("parent"), .node("child")]
        let path: [AppNavigationRoute] = [.node("parent")]
        #expect(
            AppNavigationPathPolicy.nodeCount(previousPath)
                - AppNavigationPathPolicy.nodeCount(path) == 1
        )
    }

    @Test func backButtonPopsThePresentedNativeNavigationPathFirst() {
        #expect(OutlinerNavigationPolicy.pathAfterBackButton(["parent", "child"]) == ["parent"])
        #expect(OutlinerNavigationPolicy.pathAfterBackButton(["parent"]) == [])
        #expect(OutlinerNavigationPolicy.pathAfterBackButton([String]()) == [])
    }

    @Test func pagesBlocksTagsAndOutlinerZoomUseOneNativeNodeRoute() {
        let path: [AppNavigationRoute] = [
            .node("parent"),
            .node("child"),
        ]
        #expect(AppNavigationPathPolicy.nodeCount(path) == 2)
    }

    @Test func markupNavigationDoesNotPushTheCurrentDestinationAgain() {
        let node = AppNavigationRoute.node("node-1")
        let tag = AppNavigationRoute.node("tag-1")

        #expect(!AppNavigationPathPolicy.shouldAppend(node, to: [node]))
        #expect(!AppNavigationPathPolicy.shouldAppend(tag, to: [node, tag]))
        #expect(AppNavigationPathPolicy.shouldAppend(tag, to: [node]))
        #expect(AppNavigationPathPolicy.shouldAppend(node, to: []))
    }

    @Test func relatedContentUsesLogseqSectionNamesForPopulatedNodeAndTagViews() {
        #expect(RelatedContentPolicy.sectionTitle(
            isTag: false,
            hasBlocks: true
        ) == "Linked references")
        #expect(RelatedContentPolicy.sectionTitle(
            isTag: false,
            hasBlocks: false
        ) == nil)
        #expect(RelatedContentPolicy.sectionTitle(
            isTag: true,
            hasBlocks: true
        ) == "Tagged nodes")
        #expect(RelatedContentPolicy.sectionTitle(
            isTag: true,
            hasBlocks: false
        ) == "Tagged nodes")
        #expect(RelatedContentPolicy.emptyTitle(
            isTag: true,
            hasBlocks: false
        ) == "No tagged nodes")
        #expect(RelatedContentPolicy.emptyTitle(
            isTag: true,
            hasBlocks: true
        ) == nil)
        #expect(RelatedContentPolicy.sectionTitle(isTag: false, hasBlocks: false) == nil)
    }

    @Test func relatedBlockMarkupShowsTitlesInsteadOfCanonicalUUIDs() {
        let nodes = [
            LogseqMarkupNode(type: .text, text: "E2E links "),
            LogseqMarkupNode(
                type: .nodeReference,
                uuid: "page-uuid",
                title: "E2E Page Target"
            ),
            LogseqMarkupNode(type: .text, text: " "),
            LogseqMarkupNode(
                type: .nodeReference,
                uuid: "block-uuid",
                title: "E2E Block Target"
            ),
            LogseqMarkupNode(type: .text, text: " "),
            LogseqMarkupNode(
                type: .tagReference,
                uuid: "tag-uuid",
                title: "E2E Project"
            ),
        ]
        let presentation = OutlinerMarkupPresentation.make(nodes: nodes, fallback: "unused")

        #expect(presentation.plainText ==
            "E2E links E2E Page Target E2E Block Target #E2E Project")
        #expect(!presentation.plainText.contains("page-uuid"))
        #expect(!presentation.plainText.contains("block-uuid"))
        #expect(!presentation.plainText.contains("tag-uuid"))
    }

    @Test func linkedReferencesAndTaggedNodesGroupBlocksByImmediateParent() {
        let page = LogseqEntitySummary(uuid: "page", title: "Page")
        let parent = LogseqEntitySummary(uuid: "parent", title: "Parent")
        func block(_ uuid: String, parentID: String?, breadcrumbs: [LogseqEntitySummary]) -> LogseqBlock {
            LogseqBlock(
                uuid: uuid,
                title: uuid,
                pageId: "page",
                parentId: parentID,
                createdAt: 1,
                updatedAt: 1,
                syncStatus: "synced",
                breadcrumbs: breadcrumbs
            )
        }
        let groups = RelatedBlockGrouping.groups([
            block("first", parentID: "parent", breadcrumbs: [page, parent]),
            block("second", parentID: "parent", breadcrumbs: [page, parent]),
            block("third", parentID: "page", breadcrumbs: [page]),
            block("fourth", parentID: "orphan-parent", breadcrumbs: []),
            block("fifth", parentID: nil, breadcrumbs: []),
        ])

        #expect(groups.map(\.id) == ["parent", "page", "orphan-parent"])
        #expect(groups[0].breadcrumbs == [page, parent])
        #expect(groups[0].blocks.map(\.uuid) == ["first", "second"])
        #expect(groups[2].blocks.map(\.uuid) == ["fourth"])
        #expect(groups[1].blocks.map(\.uuid) == ["third", "fifth"])
    }

    @Test func everySupportedToolbarCommandHasAnEventIconAndAccessibleTitle() {
        let expected: [OutlinerToolbarAction: (String, String, String, Bool)] = [
            .task: ("task", "checkmark.square", "Task", true),
            .outdent: ("outdent", "arrow.left", "Outdent", true),
            .indent: ("indent", "arrow.right", "Indent", true),
            .tag: ("tag", "number", "Tag", true),
            .pageReference: ("pageReference", "parentheses", "Page reference", true),
            .camera: ("camera", "camera", "Photo", false),
            .attachment: ("attachment", "paperclip", "Upload asset", false),
            .hideKeyboard: ("hideKeyboard", "keyboard.chevron.compact.down", "Hide keyboard", false),
            .copy: ("copy", "doc.on.doc", "Copy", false),
            .delete: ("delete", "trash", "Delete", false),
            .copyReference: ("copyReference", "r.square", "Copy reference", false),
            .copyURL: ("copyURL", "link", "Copy URL", false),
            .unselect: ("unselect", "xmark", "Unselect", false),
        ]
        let supported = Set(
            OutlinerToolbarPolicy.editorActions
                + [OutlinerToolbarPolicy.trailingEditorAction]
                + OutlinerToolbarPolicy.selectionActions
                + [OutlinerToolbarPolicy.trailingSelectionAction]
        )

        #expect(supported == Set(expected.keys))
        for (action, contract) in expected {
            #expect(action.eventValue == contract.0)
            #expect(action.systemImageName == contract.1)
            #expect(action.accessibilityTitle == contract.2)
            #expect(action.preservesInlineEditorFocus == contract.3)
        }
    }

    @Test func structuralEditingCommandsKeepTheInlineEditorFocused() {
        let focusPreservingActions: [OutlinerToolbarAction] = [
            .task, .outdent, .indent, .tag, .pageReference,
        ]
        for action in focusPreservingActions {
            #expect(action.preservesInlineEditorFocus)
        }
        #expect(!OutlinerToolbarAction.hideKeyboard.preservesInlineEditorFocus)
    }

    @Test func keyboardDismissalHidesTheInlineEditorBeforeCoreAcknowledgesIt() throws {
        let editing = try JSONDecoder().decode(
            LogseqOutlinerEditing.self,
            from: Data(#"{"uuid":"block","title":"Draft","caretUTF16Offset":5}"#.utf8)
        )

        #expect(OutlinerKeyboardPresentationPolicy.presentedEditing(
            coreEditing: editing,
            dismissalPending: false
        ) == editing)
        #expect(OutlinerKeyboardPresentationPolicy.presentedEditing(
            coreEditing: editing,
            dismissalPending: true
        ) == nil)
        #expect(OutlinerKeyboardPresentationPolicy.presentedEditing(
            coreEditing: nil,
            dismissalPending: true
        ) == nil)
    }

    @Test func outlinerIdleStateStillShowsTheGlobalBottomBar() {
        #expect(BottomChromePolicy.presentation(
            contentMode: LogseqContentMode.outliner,
            hasSelectedPage: false,
            composerExpanded: false,
            hasOutlinerSelection: false,
            isEditingOutlinerBlock: false
        ) == .captureAndSearch)
        #expect(BottomChromePolicy.presentation(
            contentMode: LogseqContentMode.outliner,
            hasSelectedPage: false,
            composerExpanded: false,
            hasOutlinerSelection: false,
            isEditingOutlinerBlock: true
        ) == .outlinerEditor)
        #expect(BottomChromePolicy.presentation(
            contentMode: LogseqContentMode.outliner,
            hasSelectedPage: false,
            composerExpanded: false,
            hasOutlinerSelection: true,
            isEditingOutlinerBlock: true
        ) == .outlinerSelection)
        #expect(BottomChromePolicy.presentation(
            contentMode: LogseqContentMode.outliner,
            hasSelectedPage: true,
            composerExpanded: false,
            hasOutlinerSelection: false,
            isEditingOutlinerBlock: false
        ) == .hidden)
    }

    @Test func dropZoneMapsOnlyPointerGeometry() {
        #expect(OutlinerDropZone.placement(locationY: 10, rowHeight: 100) == .before)
        #expect(OutlinerDropZone.placement(locationY: 50, rowHeight: 100) == .inside)
        #expect(OutlinerDropZone.placement(locationY: 90, rowHeight: 100) == .after)
        #expect(OutlinerDropZone.placement(locationY: 0, rowHeight: 0) == .before)
        #expect(OutlinerDropPlacement.before.eventValue == "before")
        #expect(OutlinerDropPlacement.inside.eventValue == "inside")
        #expect(OutlinerDropPlacement.after.eventValue == "after")
    }

    @Test func inlineEditorDoesNotReplaceUnacknowledgedLocalTyping() {
        #expect(InlineEditorTextReconciliationPolicy.decision(
            modelText: "H", localText: "Hello"
        ) == .keepLocal)
        #expect(InlineEditorTextReconciliationPolicy.decision(
            modelText: "Hello", localText: "Hello"
        ) == .acknowledgeLocal)
        #expect(InlineEditorTextReconciliationPolicy.decision(
            modelText: "Remote", localText: nil
        ) == .applyModel)
    }

    @Test func unchangedRowsKeepTheSameRenderIdentityAcrossUnrelatedSnapshots() throws {
        let block = try JSONDecoder().decode(
            LogseqBlock.self,
            from: Data(#"{"uuid":"block","title":"Title","pageId":"page","parentId":null,"createdAt":1,"updatedAt":1,"syncStatus":null}"#.utf8)
        )
        let row = try JSONDecoder().decode(
            LogseqOutlineRow.self,
            from: Data(#"{"block":{"uuid":"block","title":"Title","pageId":"page","parentId":null,"createdAt":1,"updatedAt":1,"syncStatus":null},"depth":0,"hasChildren":false,"isCollapsed":false}"#.utf8)
        )
        let idle = OutlinerRowRenderKey(
            row: row,
            statuses: [LogseqTaskStatus.todo, LogseqTaskStatus.done],
            isEditing: false,
            isSelected: false,
            isSelectionActive: false,
            editingTitle: block.title,
            desiredCaretUTF16Offset: nil
        )

        #expect(idle == idle)
        #expect(idle != OutlinerRowRenderKey(
            row: row,
            statuses: [LogseqTaskStatus.todo, LogseqTaskStatus.done],
            isEditing: true,
            isSelected: false,
            isSelectionActive: false,
            editingTitle: block.title,
            desiredCaretUTF16Offset: 2
        ))
    }

    @Test func inlineEditorRequestsFocusOnlyWhenAttachedAndNotAlreadyFocused() {
        #expect(InlineEditorFocusPolicy.shouldRequestFocus(
            isAttachedToWindow: true, isFirstResponder: false
        ))
        #expect(!InlineEditorFocusPolicy.shouldRequestFocus(
            isAttachedToWindow: false, isFirstResponder: false
        ))
        #expect(!InlineEditorFocusPolicy.shouldRequestFocus(
            isAttachedToWindow: true, isFirstResponder: true
        ))
    }


    @Test func inlineEditorAppliesTheNewBlockDuringResponderHandoff() {
        #expect(InlineEditorTextReconciliationPolicy.decision(
            modelText: "new block",
            localText: "previous draft",
            isSameBlock: false
        ) == .applyModel)
    }

    @Test func inlineEditorKeepsTypingBufferedAfterReturnDuringResponderHandoff() {
        #expect(InlineEditorTextReconciliationPolicy.decision(
            modelText: "suffix",
            localText: "suffixchild",
            isSameBlock: false,
            isAwaitingBlockHandoff: true
        ) == .keepLocal)
        #expect(InlineEditorTextReconciliationPolicy.decision(
            modelText: "suffixchild",
            localText: "suffixchild",
            isSameBlock: false,
            isAwaitingBlockHandoff: true
        ) == .acknowledgeLocal)
    }

    @Test func returnTransitionImmediatelyPresentsTheNewBlockSuffix() {
        #expect(InlineEditorReturnTransition.localText(
            text: "parent child",
            replacementRange: NSRange(location: 7, length: 0)
        ) == "child")
        #expect(InlineEditorReturnTransition.localText(
            text: "parent selected child",
            replacementRange: NSRange(location: 7, length: 9)
        ) == "child")
        #expect(InlineEditorReturnTransition.localText(
            text: "abc",
            replacementRange: NSRange(location: 99, length: 0)
        ) == "")
    }
}
