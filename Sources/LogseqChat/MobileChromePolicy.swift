import Foundation
import LogseqChatModel

enum MobileChromeRegion {
    case header
    case footer
}

enum MobileChromeSurface: Equatable {
    case monochromeLiquid
    case transparent
}

enum MobileChromePlacement: Equatable {
    case navigationContainerOverlay
}

enum MobileChromePolicy {
    static let mainPanelSpansFullScreenHeight = true
    static let ignoresContainerSafeArea = true
    static let ignoresKeyboardSafeArea = false
    static let footerOccupiesLayoutSpace = false
    static let mainPanelBottomSafeAreaPadding: CGFloat = 0
    static let bottomControlScreenEdgeInset: CGFloat = 21
    static let minimumScrollableBottomClearance: CGFloat = 120
    static let footerPlacement = MobileChromePlacement.navigationContainerOverlay

    static func surface(for region: MobileChromeRegion) -> MobileChromeSurface {
        switch region {
        case .header:
            return .monochromeLiquid
        case .footer:
            return .transparent
        }
    }

    static func extendsIntoSystemSafeArea(_ region: MobileChromeRegion) -> Bool {
        true
    }

    static func drawsDivider(for region: MobileChromeRegion) -> Bool {
        false
    }
}

enum BottomChromePresentation: Equatable {
    case hidden
    case captureAndSearch
    case expandedComposer
    case outlinerEditor
    case outlinerSelection
}

enum BottomChromePolicy {
    static func presentation(
        contentMode: LogseqContentMode,
        hasSelectedPage: Bool,
        composerExpanded: Bool,
        hasOutlinerSelection: Bool,
        isEditingOutlinerBlock: Bool
    ) -> BottomChromePresentation {
        if contentMode == .outliner && hasOutlinerSelection { return .outlinerSelection }
        if contentMode == .outliner && isEditingOutlinerBlock { return .outlinerEditor }
        if hasSelectedPage { return .hidden }
        if composerExpanded { return .expandedComposer }
        return .captureAndSearch
    }
}

enum GraphLaunchPolicy {
    static func shouldShowPicker(
        snapshotSelectedGraphID: String?,
        persistedSelectedGraphID: String,
        isGraphsPresented: Bool = false
    ) -> Bool {
        if isGraphsPresented { return false }
        let snapshotHasGraph = !(snapshotSelectedGraphID ?? "").isEmpty
        return !snapshotHasGraph && persistedSelectedGraphID.isEmpty
    }
}

enum BlockListUpdatePolicy {
    static func shouldScrollToBottom(
        oldBlockIDs: Set<String>,
        newBlockIDs: Set<String>
    ) -> Bool {
        !newBlockIDs.isSubset(of: oldBlockIDs)
    }
}
