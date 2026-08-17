enum SidebarContentItem: String, CaseIterable {
    case journals
    case graphs
    case favorites
    case recent

    var title: String {
        switch self {
        case .journals: return "Journals"
        case .graphs: return "Graphs"
        case .favorites: return "Favorites"
        case .recent: return "Recent"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .journals: return "link.sidebar.journals"
        case .graphs: return "link.sidebar.graphs"
        case .favorites: return "section.sidebar.favorites"
        case .recent: return "section.sidebar.recent"
        }
    }
}
