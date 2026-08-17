import Testing
@testable import LogseqChat

@Suite struct SidebarDragPolicyTests {
    @Test @MainActor func motionStateCommitsTheDragWithoutOwningJournalContent() {
        let motion = SidebarMotionState()
        motion.dragOffset = 120
        motion.setPresented(true)

        #expect(motion.isPresented)
        #expect(motion.dragOffset == 0)
    }

    @Test func downwardPullNeverOpensClosedSidebar() {
        #expect(!SidebarDragPolicy.accepts(
            translationX: 5,
            translationY: 120
        ))
        #expect(!SidebarDragPolicy.presentedAfterDrag(
            isPresented: false,
            translationX: 5,
            translationY: 120,
            predictedTranslationX: 5,
            sidebarWidth: 320
        ))
    }

    @Test func verticalListScrollNeverOpensFromIncidentalHorizontalPrediction() {
        #expect(!SidebarDragPolicy.presentedAfterDrag(
            isPresented: false,
            translationX: 18,
            translationY: 180,
            predictedTranslationX: 260,
            sidebarWidth: 320
        ))
    }

    @Test func verticalSidebarScrollNeverClosesFromIncidentalHorizontalPrediction() {
        #expect(SidebarDragPolicy.presentedAfterDrag(
            isPresented: true,
            translationX: -18,
            translationY: -180,
            predictedTranslationX: -260,
            sidebarWidth: 320
        ))
    }

    @Test func exactlyDiagonalDragDoesNotChangeSidebarState() {
        #expect(!SidebarDragPolicy.presentedAfterDrag(
            isPresented: false,
            translationX: 80,
            translationY: 80,
            predictedTranslationX: 260,
            sidebarWidth: 320
        ))
        #expect(SidebarDragPolicy.presentedAfterDrag(
            isPresented: true,
            translationX: -80,
            translationY: -80,
            predictedTranslationX: -260,
            sidebarWidth: 320
        ))
    }

    @Test func horizontalSwipeCanOpenFromAnywhereOnTheMainPanel() {
        #expect(SidebarDragPolicy.accepts(
            translationX: 220,
            translationY: 4
        ))
        #expect(SidebarDragPolicy.presentedAfterDrag(
            isPresented: false,
            translationX: 220,
            translationY: 4,
            predictedTranslationX: 300,
            sidebarWidth: 320
        ))
    }

    @Test func demoTracksHorizontalMovementAfterThreePoints() {
        #expect(SidebarDragPolicy.minimumDistance == 3)
        #expect(SidebarDragPolicy.accepts(
            translationX: 4,
            translationY: 3
        ))
    }

    @Test func demoUsesSimpleHorizontalDominance() {
        #expect(SidebarDragPolicy.accepts(
            translationX: 10,
            translationY: 9
        ))
    }

    @Test func demoTracksBothDirectionsAndLetsClampingHandleTheBounds() {
        #expect(SidebarDragPolicy.accepts(
            translationX: -40,
            translationY: 2
        ))
        #expect(SidebarDragPolicy.accepts(
            translationX: 40,
            translationY: 2
        ))
    }

    @Test func dragStateIgnoresMovementAwayFromTheAvailableSidebarRange() {
        #expect(SidebarDragPolicy.dragOffset(isPresented: false, translationX: -40) == 0)
        #expect(SidebarDragPolicy.dragOffset(isPresented: false, translationX: 40) == 40)
        #expect(SidebarDragPolicy.dragOffset(isPresented: true, translationX: 40) == 0)
        #expect(SidebarDragPolicy.dragOffset(isPresented: true, translationX: -40) == -40)
    }

    @Test func editorAndSelectionDisableSidebarActivationUntilTheyExit() {
        #expect(SidebarDragPolicy.allowsActivation(
            isPresented: false,
            isEditingOutlinerBlock: false,
            hasOutlinerSelection: false
        ))
        #expect(!SidebarDragPolicy.allowsActivation(
            isPresented: false,
            isEditingOutlinerBlock: true,
            hasOutlinerSelection: false
        ))
        #expect(!SidebarDragPolicy.allowsActivation(
            isPresented: false,
            isEditingOutlinerBlock: false,
            hasOutlinerSelection: true
        ))
        #expect(SidebarDragPolicy.allowsActivation(
            isPresented: true,
            isEditingOutlinerBlock: true,
            hasOutlinerSelection: true
        ))
    }

    @Test func nativeNavigationDestinationsOwnTheLeadingEdgeGesture() {
        #expect(!SidebarDragPolicy.allowsActivation(
            isPresented: false,
            isEditingOutlinerBlock: false,
            hasOutlinerSelection: false,
            hasPresentedNavigation: true
        ))
        #expect(SidebarDragPolicy.allowsActivation(
            isPresented: false,
            isEditingOutlinerBlock: false,
            hasOutlinerSelection: false,
            hasPresentedNavigation: false
        ))
    }

    @Test func demoUsesProjectedEndEvenForAShortFastSwipe() {
        #expect(SidebarDragPolicy.presentedAfterDrag(
            isPresented: false,
            translationX: 4,
            translationY: 3,
            predictedTranslationX: 220,
            sidebarWidth: 320
        ))
    }

    @Test func scrollingLocksOnlyWhileSidebarIsDraggingOrAnimating() {
        #expect(!SidebarDragPolicy.locksScrolling(isDragging: false, isAnimating: false))
        #expect(SidebarDragPolicy.locksScrolling(isDragging: true, isAnimating: false))
        #expect(SidebarDragPolicy.locksScrolling(isDragging: false, isAnimating: true))
        #expect(SidebarDragPolicy.locksScrolling(isDragging: true, isAnimating: true))
    }

    @Test func animationBlocksTouchesWithoutReconfiguringTheOutlinerScrollView() {
        #expect(!SidebarDragPolicy.disablesScrollEnvironment(
            isDragging: false,
            isAnimating: true
        ))
        #expect(SidebarDragPolicy.blocksMainInteraction(
            isAnimating: true
        ))
        #expect(!SidebarDragPolicy.blocksMainInteraction(
            isAnimating: false
        ))
    }

    @Test func sidebarLinksAreInteractiveOnlyWhenFullyOpenAndIdle() {
        #expect(SidebarDragPolicy.allowsSidebarInteraction(
            isPresented: true,
            isDragging: false,
            isAnimating: false
        ))
        #expect(!SidebarDragPolicy.allowsSidebarInteraction(
            isPresented: true,
            isDragging: true,
            isAnimating: false
        ))
        #expect(!SidebarDragPolicy.allowsSidebarInteraction(
            isPresented: true,
            isDragging: false,
            isAnimating: true
        ))
        #expect(!SidebarDragPolicy.allowsSidebarInteraction(
            isPresented: false,
            isDragging: false,
            isAnimating: false
        ))
    }

    @Test func leadingEdgeHorizontalSwipeOpensPastThreshold() {
        #expect(SidebarDragPolicy.accepts(
            translationX: 90,
            translationY: 8
        ))
        #expect(SidebarDragPolicy.presentedAfterDrag(
            isPresented: false,
            translationX: 90,
            translationY: 8,
            predictedTranslationX: 220,
            sidebarWidth: 320
        ))
    }

    @Test func shortHorizontalSwipeStaysClosed() {
        #expect(!SidebarDragPolicy.presentedAfterDrag(
            isPresented: false,
            translationX: 40,
            translationY: 3,
            predictedTranslationX: 90,
            sidebarWidth: 320
        ))
    }

    @Test func openSidebarUsesProjectedEndPosition() {
        #expect(!SidebarDragPolicy.presentedAfterDrag(
            isPresented: true,
            translationX: -180,
            translationY: 8,
            predictedTranslationX: -240,
            sidebarWidth: 320
        ))
        #expect(SidebarDragPolicy.presentedAfterDrag(
            isPresented: true,
            translationX: -5,
            translationY: 130,
            predictedTranslationX: -5,
            sidebarWidth: 320
        ))
    }
}
