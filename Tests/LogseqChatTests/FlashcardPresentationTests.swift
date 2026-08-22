import Testing
import LogseqChatModel
@testable import LogseqChat

@Suite struct FlashcardPresentationTests {
    @Test func questionMasksClozeWithoutHidingItsContext() {
        let nodes = [
            LogseqMarkupNode(type: .text, text: "The capital is "),
            LogseqMarkupNode(type: .cloze, text: "Paris"),
            LogseqMarkupNode(type: .text, text: ".")
        ]

        #expect(FlashcardPresentation.text(nodes: nodes, fallback: "", revealCloze: false)
            == "The capital is […].")
        #expect(FlashcardPresentation.text(nodes: nodes, fallback: "", revealCloze: true)
            == "The capital is Paris.")
        #expect(FlashcardPresentation.containsCloze(nodes: nodes, fallback: ""))
    }

    @Test func fallbackTitlePreservesLegacyClozeCards() {
        let title = "The capital is {{cloze Paris}}."

        #expect(FlashcardPresentation.text(nodes: [], fallback: title, revealCloze: false)
            == "The capital is […].")
        #expect(FlashcardPresentation.text(nodes: [], fallback: title, revealCloze: true)
            == "The capital is Paris.")
        #expect(FlashcardPresentation.containsCloze(nodes: [], fallback: title))
    }
}
