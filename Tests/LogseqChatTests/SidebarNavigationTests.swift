import Testing
@testable import LogseqChat

@Suite struct SidebarNavigationTests {
    @Test func mobileTabsDefaultToEveryPrimaryDestination() {
        #expect(SidebarTabPolicy.selectedItems(rawValue: "") == [
            SidebarContentItem.journals,
            SidebarContentItem.flashcards,
            SidebarContentItem.graphs,
        ])
        #expect(SidebarTabPolicy.sidebarItems(rawValue: "") == [
            SidebarContentItem.journals,
            SidebarContentItem.flashcards,
            SidebarContentItem.graphs,
            SidebarContentItem.favorites,
            SidebarContentItem.recent,
        ])
    }

    @Test func mobileTabsKeepJournalsAndDiscardUnknownOrDuplicateValues() {
        #expect(SidebarTabPolicy.selectedItems(
            rawValue: "graphs,graphs,unknown,flashcards"
        ) == [
            SidebarContentItem.journals,
            SidebarContentItem.graphs,
            SidebarContentItem.flashcards,
        ])
    }

    @Test func mobileTabsPersistDisabledAndReorderedDestinations() {
        let withoutFlashcards = SidebarTabPolicy.updatedRawValue(
            "journals,flashcards,graphs",
            item: SidebarContentItem.flashcards,
            isEnabled: false
        )
        #expect(withoutFlashcards == "journals,graphs")
        #expect(SidebarTabPolicy.selectedItems(rawValue: withoutFlashcards) == [
            SidebarContentItem.journals,
            SidebarContentItem.graphs,
        ])
        #expect(SidebarTabPolicy.rawValue(for: [
            SidebarContentItem.journals,
            SidebarContentItem.graphs,
            SidebarContentItem.flashcards,
        ])
            == "journals,graphs,flashcards")
    }

    @Test func journalsAndGraphsCannotBeDisabled() {
        #expect(SidebarTabPolicy.selectedItems(rawValue: "journals") == [
            SidebarContentItem.journals,
            SidebarContentItem.graphs,
        ])
        #expect(SidebarTabPolicy.updatedRawValue(
            "journals,graphs",
            item: SidebarContentItem.journals,
            isEnabled: false
        ) == "journals,graphs")
        #expect(SidebarTabPolicy.updatedRawValue(
            "journals,flashcards,graphs",
            item: SidebarContentItem.graphs,
            isEnabled: false
        ) == "journals,flashcards,graphs")
    }

    @Test func mobileTabsReorderWithoutMovingTheRequiredJournalTab() {
        #expect(SidebarTabPolicy.movedRawValue(
            "journals,flashcards,graphs",
            item: SidebarContentItem.graphs,
            offset: -1
        ) == "journals,graphs,flashcards")
        #expect(SidebarTabPolicy.movedRawValue(
            "journals,flashcards,graphs",
            item: SidebarContentItem.flashcards,
            offset: -1
        ) == "journals,flashcards,graphs")
    }

    @Test func journalsAppearsBeforeDynamicPageSections() {
        let expected: [SidebarContentItem] = [.journals, .flashcards, .graphs, .favorites, .recent]
        #expect(SidebarContentItem.allCases == expected)
        #expect(SidebarContentItem.journals.title == "Journals")
        #expect(SidebarContentItem.journals.accessibilityIdentifier == "link.sidebar.journals")
        #expect(SidebarContentItem.graphs.title == "Graphs")
        #expect(SidebarContentItem.graphs.accessibilityIdentifier == "link.sidebar.graphs")
        #expect(SidebarContentItem.flashcards.title == "Flashcards")
        #expect(SidebarContentItem.flashcards.accessibilityIdentifier == "link.sidebar.flashcards")
        #expect(SidebarContentItem.favorites.title == "Favorites")
        #expect(SidebarContentItem.favorites.accessibilityIdentifier == "section.sidebar.favorites")
        #expect(SidebarContentItem.recent.title == "Recent")
        #expect(SidebarContentItem.recent.accessibilityIdentifier == "section.sidebar.recent")
    }

    @Test func graphsAndJournalsReplaceMainContentWithoutPushingNavigation() {
        #expect(SidebarDestinationPolicy.presentation(
            for: SidebarContentItem.journals
        ) == SidebarPrimaryPresentation.journals)
        #expect(SidebarDestinationPolicy.presentation(
            for: SidebarContentItem.graphs
        ) == SidebarPrimaryPresentation.graphs)
        #expect(SidebarDestinationPolicy.presentation(
            for: SidebarContentItem.flashcards
        ) == SidebarPrimaryPresentation.flashcards)
        #expect(SidebarDestinationPolicy.closesSidebar(for: SidebarContentItem.journals))
        #expect(SidebarDestinationPolicy.closesSidebar(for: SidebarContentItem.graphs))
        #expect(SidebarDestinationPolicy.closesSidebar(for: SidebarContentItem.flashcards))
        #expect(!SidebarDestinationPolicy.pushesNavigation(for: SidebarContentItem.journals))
        #expect(!SidebarDestinationPolicy.pushesNavigation(for: SidebarContentItem.graphs))
    }
}
