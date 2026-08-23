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
        #expect(MobileChromePolicy.editorBottomScreenEdgeInset <
            MobileChromePolicy.bottomControlScreenEdgeInset)
        #expect(BottomChromePolicy.occupiesLayoutSpace(BottomChromePresentation.outlinerEditor))
        #expect(!BottomChromePolicy.occupiesLayoutSpace(BottomChromePresentation.captureAndSearch))
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

    @Test func bottomChromePriorityCoversComposerAndIdleStates() {
        #expect(BottomChromePolicy.presentation(
            contentMode: LogseqContentMode.chat,
            hasSelectedPage: false,
            composerExpanded: true,
            hasOutlinerSelection: false,
            isEditingOutlinerBlock: false
        ) == .expandedComposer)
    }

    @Test func screensWithoutCaptureHideBottomChrome() {
        #expect(BottomChromePolicy.presentation(
            contentMode: LogseqContentMode.outliner,
            hasSelectedPage: false,
            composerExpanded: false,
            hasOutlinerSelection: false,
            isEditingOutlinerBlock: false,
            showsComposer: false
        ) == .hidden)
    }

    @Test func onlyNewBlocksScrollTheListToTheBottom() {
        #expect(BlockListUpdatePolicy.shouldScrollToBottom(
            oldBlockIDs: ["old"],
            newBlockIDs: ["old", "captured"]
        ))
        #expect(BlockListUpdatePolicy.shouldScrollToBottom(
            oldBlockIDs: ["local"],
            newBlockIDs: ["authoritative"]
        ))
        #expect(!BlockListUpdatePolicy.shouldScrollToBottom(
            oldBlockIDs: ["old"],
            newBlockIDs: ["old"]
        ))
    }

    @Test func journalHomeUsesJournalAsItsHeading() {
        #expect(AppHeaderPolicy.title(zoomedBlockTitle: nil, selectedPageTitle: nil) == "Journal")
        #expect(AppHeaderPolicy.title(
            zoomedBlockTitle: nil,
            selectedPageTitle: "Project"
        ) == "Project")
        #expect(AppHeaderPolicy.title(
            zoomedBlockTitle: "Focused block",
            selectedPageTitle: "Project"
        ) == "Focused block")
    }

    @Test func settingsUsesTheCircledEllipsisSystemSymbol() {
        #expect(HeaderControlPolicy.settingsSystemImage == "ellipsis.circle")
    }

    @Test func iOS26GroupsOnlySyncAndSettingsInTheNativeToolbar() {
        #expect(HeaderControlPolicy.usesNativeToolbarGroup)
        #expect(!HeaderControlPolicy.showsContentModeControl)
        #expect(HeaderControlPolicy.trailingGroupActionCount == 2)
        #expect(HeaderControlPolicy.syncIndicatorOpensStatusSheet)
    }

    @Test func sidebarToggleUsesTwoAsymmetricLinesInACircularPrimaryControl() {
        #expect(SidebarMenuIconPolicy.assetName == "sidebar_toggle")
        #expect(SidebarMenuIconPolicy.assetSize == 24)
        #expect(SidebarMenuIconPolicy.usesTemplateRendering)
        #expect(SidebarMenuIconPolicy.usesPrimaryStyle)
        #expect(SidebarMenuIconPolicy.usesCircularButtonShape)
        #expect(!SidebarMenuIconPolicy.addsExplicitGlassStyleInsideToolbar)
        #expect(SidebarMenuIconPolicy.topLineWidth > SidebarMenuIconPolicy.bottomLineWidth)
    }

    @Test func offlineSSEFailuresStayOutOfContentErrorBanners() {
        #expect(!AppErrorPresentationPolicy.shouldPresent(code: "sse_connection_failed"))
        #expect(!AppErrorPresentationPolicy.shouldPresent(code: "snapshot_required"))
        #expect(AppErrorPresentationPolicy.shouldPresent(code: "outliner_effect_failed"))
    }

    @Test func syncIndicatorUsesLivePumpStateInsteadOfCachedBlockStatus() {
        #expect(!SyncIndicatorPolicy.hasUnconfirmedChanges(
            hasPendingSemanticOperations: false,
            hasPendingTransportRequest: false,
            cachedBlockStatuses: ["pending", "submitted", "synced", nil]
        ))
        #expect(SyncIndicatorPolicy.hasUnconfirmedChanges(
            hasPendingSemanticOperations: true,
            hasPendingTransportRequest: false,
            cachedBlockStatuses: []
        ))
        #expect(SyncIndicatorPolicy.hasUnconfirmedChanges(
            hasPendingSemanticOperations: false,
            hasPendingTransportRequest: true,
            cachedBlockStatuses: []
        ))
        #expect(SyncIndicatorPolicy.hasUnconfirmedChanges(
            hasPendingSemanticOperations: false,
            hasPendingTransportRequest: false,
            cachedBlockStatuses: ["failed"]
        ))
    }

    @Test func syncStatusSummaryExplainsTheCurrentState() {
        #expect(SyncStatusDetailPolicy.summary(
            isConnected: true, hasPendingChanges: false, hasFailedChanges: false
        ) == "Up to date")
        #expect(SyncStatusDetailPolicy.summary(
            isConnected: true, hasPendingChanges: true, hasFailedChanges: false
        ) == "Saving changes")
        #expect(SyncStatusDetailPolicy.summary(
            isConnected: false, hasPendingChanges: true, hasFailedChanges: false
        ) == "Waiting for connection")
        #expect(SyncStatusDetailPolicy.summary(
            isConnected: true, hasPendingChanges: false, hasFailedChanges: true
        ) == "Sync needs attention")
    }

    @Test func syncIndicatorUsesRedForDisconnectedOrFailedSync() {
        #expect(SyncIndicatorPolicy.state(
            isConnected: true, hasPendingChanges: false, hasFailedChanges: false, hasSyncError: false
        ) == .green)
        #expect(SyncIndicatorPolicy.state(
            isConnected: true, hasPendingChanges: true, hasFailedChanges: false, hasSyncError: false
        ) == .yellow)
        #expect(SyncIndicatorPolicy.state(
            isConnected: false, hasPendingChanges: true, hasFailedChanges: false, hasSyncError: false
        ) == .red)
        #expect(SyncIndicatorPolicy.state(
            isConnected: true, hasPendingChanges: true, hasFailedChanges: true, hasSyncError: false
        ) == .red)
        #expect(SyncIndicatorPolicy.state(
            isConnected: true, hasPendingChanges: true, hasFailedChanges: false, hasSyncError: true
        ) == .red)
    }

    @Test func deferredSnapshotRefreshKeepsTheSyncConnectionAvailableWhileEditing() {
        #expect(SyncConnectionPolicy.isAvailable(
            isConnected: false,
            snapshotRefreshDeferred: true
        ))
        #expect(!SyncConnectionPolicy.isAvailable(
            isConnected: false,
            snapshotRefreshDeferred: false
        ))
    }
}
