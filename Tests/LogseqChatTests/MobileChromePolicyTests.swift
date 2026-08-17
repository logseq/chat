import Testing
import LogseqChatModel
@testable import LogseqChat

@Suite struct MobileChromePolicyTests {
    @Test func headerUsesOneContinuousMonochromeLiquidSurface() {
        #expect(
            MobileChromePolicy.surface(for: MobileChromeRegion.header)
                == MobileChromeSurface.monochromeLiquid
        )
        #expect(MobileChromePolicy.extendsIntoSystemSafeArea(MobileChromeRegion.header))
    }

    @Test func footerContainerIsTransparent() {
        #expect(
            MobileChromePolicy.surface(for: MobileChromeRegion.footer)
                == MobileChromeSurface.transparent
        )
        #expect(!MobileChromePolicy.drawsDivider(for: MobileChromeRegion.footer))
        #expect(!MobileChromePolicy.footerOccupiesLayoutSpace)
        #expect(MobileChromePolicy.minimumScrollableBottomClearance >= 110)
    }

    @Test func floatingFooterUsesTheScreenEdgeInsteadOfTheContentSafeArea() {
        #expect(MobileChromePolicy.extendsIntoSystemSafeArea(MobileChromeRegion.footer))
        #expect(MobileChromePolicy.footerPlacement == .navigationContainerOverlay)
        #expect(MobileChromePolicy.bottomControlScreenEdgeInset == 21)
    }

    @Test func shiftedMainPanelAlwaysSpansTheFullScreenHeight() {
        #expect(MobileChromePolicy.mainPanelSpansFullScreenHeight)
    }

    @Test func fullScreenShellRespectsKeyboardSafeArea() {
        #expect(MobileChromePolicy.ignoresContainerSafeArea)
        #expect(!MobileChromePolicy.ignoresKeyboardSafeArea)
    }

    @Test func coldStartWithPersistedGraphSkipsPickerBeforeSnapshotRestores() {
        #expect(!GraphLaunchPolicy.shouldShowPicker(
            snapshotSelectedGraphID: nil,
            persistedSelectedGraphID: "graph-1"
        ))
    }

    @Test func coldStartWithoutPersistedOrRestoredGraphShowsPicker() {
        #expect(GraphLaunchPolicy.shouldShowPicker(
            snapshotSelectedGraphID: nil,
            persistedSelectedGraphID: "",
            isGraphsPresented: false
        ))
    }

    @Test func deletingTheSelectedGraphKeepsTheGraphsPageVisible() {
        #expect(!GraphLaunchPolicy.shouldShowPicker(
            snapshotSelectedGraphID: nil,
            persistedSelectedGraphID: "",
            isGraphsPresented: true
        ))
    }

    @Test func restoredSnapshotKeepsShellVisibleWhilePersistenceCatchesUp() {
        #expect(!GraphLaunchPolicy.shouldShowPicker(
            snapshotSelectedGraphID: "graph-1",
            persistedSelectedGraphID: ""
        ))
        #expect(!GraphLaunchPolicy.shouldShowPicker(
            snapshotSelectedGraphID: "",
            persistedSelectedGraphID: "graph-1"
        ))
    }

    @Test func bottomChromePriorityCoversSearchComposerAndIdleStates() {
        #expect(BottomChromePolicy.presentation(
            contentMode: LogseqContentMode.chat,
            hasSelectedPage: false,
            isSearching: true,
            composerExpanded: true,
            hasOutlinerSelection: false,
            isEditingOutlinerBlock: false
        ) == .hidden)
        #expect(BottomChromePolicy.presentation(
            contentMode: LogseqContentMode.chat,
            hasSelectedPage: false,
            isSearching: false,
            composerExpanded: true,
            hasOutlinerSelection: false,
            isEditingOutlinerBlock: false
        ) == .expandedComposer)
    }

    @Test func restoringSearchResultsDoesNotLookLikeANewCapture() {
        #expect(!BlockListUpdatePolicy.shouldScrollToBottom(
            oldBlockIDs: ["old"],
            newBlockIDs: ["old", "search-result"],
            queryIsEmpty: true,
            isRestoringSearchProjection: true
        ))
        #expect(BlockListUpdatePolicy.shouldScrollToBottom(
            oldBlockIDs: ["old"],
            newBlockIDs: ["old", "captured"],
            queryIsEmpty: true,
            isRestoringSearchProjection: false
        ))
        #expect(BlockListUpdatePolicy.shouldScrollToBottom(
            oldBlockIDs: ["local"],
            newBlockIDs: ["authoritative"],
            queryIsEmpty: true,
            isRestoringSearchProjection: false
        ))
        #expect(!BlockListUpdatePolicy.shouldScrollToBottom(
            oldBlockIDs: ["old"],
            newBlockIDs: ["old"],
            queryIsEmpty: true,
            isRestoringSearchProjection: false
        ))
    }
}
