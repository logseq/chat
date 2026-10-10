import Testing
@testable import LUIAppleBackend

@Suite("Drawer interaction policy")
struct LUIDrawerInteractionPolicyTests {
    @Test("content controls stay enabled while the drawer is idle")
    func idleContentControlsRemainEnabled() {
        #expect(LUIDrawerInteractionPolicy.contentControlsAreEnabled(
            isDragging: false,
            isAnimating: false,
            isGestureActive: false
        ))
    }

    @Test(
        "content controls are disabled for every active drawer interaction",
        arguments: [
            (isDragging: true, isAnimating: false, isGestureActive: false),
            (isDragging: false, isAnimating: true, isGestureActive: false),
            (isDragging: false, isAnimating: false, isGestureActive: true),
            (isDragging: true, isAnimating: true, isGestureActive: true),
        ]
    )
    func activeDrawerInteractionDisablesContentControls(
        state: (isDragging: Bool, isAnimating: Bool, isGestureActive: Bool)
    ) {
        #expect(!LUIDrawerInteractionPolicy.contentControlsAreEnabled(
            isDragging: state.isDragging,
            isAnimating: state.isAnimating,
            isGestureActive: state.isGestureActive
        ))
    }
}
