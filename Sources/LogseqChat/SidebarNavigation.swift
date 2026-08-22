enum SidebarContentItem: String, CaseIterable {
    case journals
    case flashcards
    case graphs
    case favorites
    case recent

    var title: String {
        switch self {
        case .journals: return "Journals"
        case .flashcards: return "Flashcards"
        case .graphs: return "Graphs"
        case .favorites: return "Favorites"
        case .recent: return "Recent"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .journals: return "link.sidebar.journals"
        case .flashcards: return "link.sidebar.flashcards"
        case .graphs: return "link.sidebar.graphs"
        case .favorites: return "section.sidebar.favorites"
        case .recent: return "section.sidebar.recent"
        }
    }
}

enum SidebarPrimaryPresentation: Equatable {
    case journals
    case flashcards
    case graphs
}

enum SidebarDestinationPolicy {
    static func presentation(for item: SidebarContentItem) -> SidebarPrimaryPresentation {
        switch item {
        case .graphs: return .graphs
        case .flashcards: return .flashcards
        case .journals, .favorites, .recent: return .journals
        }
    }

    static func closesSidebar(for item: SidebarContentItem) -> Bool {
        item == .journals || item == .flashcards || item == .graphs
    }

    static func pushesNavigation(for item: SidebarContentItem) -> Bool {
        false
    }
}
