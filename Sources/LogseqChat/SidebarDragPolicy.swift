import Foundation

enum SidebarDragPolicy {
    static let minimumDistance: CGFloat = 3

    static func accepts(
        translationX: CGFloat,
        translationY: CGFloat
    ) -> Bool {
        abs(translationX) > abs(translationY)
    }

    static func dragOffset(isPresented: Bool, translationX: CGFloat) -> CGFloat {
        isPresented ? min(translationX, 0) : max(translationX, 0)
    }

    static func allowsActivation(
        isPresented: Bool,
        isEditingOutlinerBlock: Bool,
        hasOutlinerSelection: Bool,
        hasPresentedNavigation: Bool = false
    ) -> Bool {
        isPresented || (!isEditingOutlinerBlock
            && !hasOutlinerSelection
            && !hasPresentedNavigation)
    }

    static func presentedAfterDrag(
        isPresented: Bool,
        translationX: CGFloat,
        translationY: CGFloat,
        predictedTranslationX: CGFloat,
        sidebarWidth: CGFloat
    ) -> Bool {
        guard accepts(translationX: translationX, translationY: translationY) else {
            return isPresented
        }
        let baseOffset = isPresented ? sidebarWidth : 0
        return baseOffset + predictedTranslationX > sidebarWidth * 0.5
    }

    static func locksScrolling(isDragging: Bool, isAnimating: Bool) -> Bool {
        isDragging || isAnimating
    }

    static func disablesScrollEnvironment(isDragging: Bool, isAnimating: Bool) -> Bool {
        _ = isAnimating
        return isDragging
    }

    static func blocksMainInteraction(isAnimating: Bool) -> Bool {
        isAnimating
    }

    static func allowsSidebarInteraction(
        isPresented: Bool,
        isDragging: Bool,
        isAnimating: Bool
    ) -> Bool {
        isPresented && !isDragging && !isAnimating
    }
}
