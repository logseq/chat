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

enum SidebarTabPolicy {
    static let configurableItems: [SidebarContentItem] = [
        .journals, .flashcards, .graphs,
    ]

    static func selectedItems(rawValue: String) -> [SidebarContentItem] {
        let requested = rawValue.isEmpty
            ? configurableItems
            : rawValue.split(separator: ",").compactMap {
                SidebarContentItem(rawValue: String($0))
            }
        var selected: [SidebarContentItem] = []
        for item in requested where configurableItems.contains(item) && !selected.contains(item) {
            selected.append(item)
        }
        selected.removeAll { $0 == .journals }
        selected.insert(.journals, at: 0)
        return selected
    }

    static func sidebarItems(rawValue: String) -> [SidebarContentItem] {
        selectedItems(rawValue: rawValue) + [.favorites, .recent]
    }

    static func rawValue(for items: [SidebarContentItem]) -> String {
        selectedItems(rawValue: items.map(\.rawValue).joined(separator: ","))
            .map(\.rawValue)
            .joined(separator: ",")
    }

    static func updatedRawValue(
        _ rawValue: String,
        item: SidebarContentItem,
        isEnabled: Bool
    ) -> String {
        var selected = selectedItems(rawValue: rawValue)
        if isEnabled {
            if configurableItems.contains(item), !selected.contains(item) {
                selected.append(item)
            }
        } else if item != .journals {
            selected.removeAll { $0 == item }
        }
        return self.rawValue(for: selected)
    }

    static func movedRawValue(
        _ rawValue: String,
        item: SidebarContentItem,
        offset: Int
    ) -> String {
        var selected = selectedItems(rawValue: rawValue)
        guard item != .journals,
              let source = selected.firstIndex(of: item) else {
            return self.rawValue(for: selected)
        }
        let destination = min(max(source + offset, 1), selected.count - 1)
        guard source != destination else { return self.rawValue(for: selected) }
        selected.swapAt(source, destination)
        return self.rawValue(for: selected)
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
