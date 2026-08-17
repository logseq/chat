import Testing
@testable import LogseqChat

@Suite struct SidebarNavigationTests {
    @Test func journalsAppearsBeforeDynamicPageSections() {
        let expected: [SidebarContentItem] = [.journals, .graphs, .favorites, .recent]
        #expect(SidebarContentItem.allCases == expected)
        #expect(SidebarContentItem.journals.title == "Journals")
        #expect(SidebarContentItem.journals.accessibilityIdentifier == "link.sidebar.journals")
        #expect(SidebarContentItem.graphs.title == "Graphs")
        #expect(SidebarContentItem.graphs.accessibilityIdentifier == "link.sidebar.graphs")
        #expect(SidebarContentItem.favorites.title == "Favorites")
        #expect(SidebarContentItem.favorites.accessibilityIdentifier == "section.sidebar.favorites")
        #expect(SidebarContentItem.recent.title == "Recent")
        #expect(SidebarContentItem.recent.accessibilityIdentifier == "section.sidebar.recent")
    }
}
