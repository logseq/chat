import SwiftUI
import LogseqChatModel

enum FlashcardPresentation {
    static func containsCloze(nodes: [LogseqMarkupNode], fallback: String) -> Bool {
        nodes.contains(where: containsCloze) || fallback.lowercased().contains("{{cloze ")
    }

    static func text(
        nodes: [LogseqMarkupNode],
        fallback: String,
        revealCloze: Bool
    ) -> String {
        guard !nodes.isEmpty else {
            return replacingLegacyClozes(in: fallback, reveal: revealCloze)
        }
        return nodes.map { text(node: $0, revealCloze: revealCloze) }.joined()
    }

    private static func containsCloze(_ node: LogseqMarkupNode) -> Bool {
        node.type == .cloze || node.children.contains(where: containsCloze)
    }

    private static func text(node: LogseqMarkupNode, revealCloze: Bool) -> String {
        switch node.type {
        case .cloze:
            return revealCloze ? (node.text ?? "") : "[…]"
        case .nodeReference:
            return node.title ?? ""
        case .tagReference:
            return "#" + (node.title ?? "")
        case .link:
            let label = node.children.map { text(node: $0, revealCloze: revealCloze) }.joined()
            return label.isEmpty ? (node.url ?? "") : label
        case .emphasis, .quote:
            return node.children.map { text(node: $0, revealCloze: revealCloze) }.joined()
        case .video, .iframe:
            return node.url ?? ""
        case .text, .code, .codeBlock, .math:
            return node.text ?? ""
        }
    }

    private static func replacingLegacyClozes(in value: String, reveal: Bool) -> String {
        var result = ""
        var remaining = value[...]
        while let start = remaining.range(
            of: "{{cloze ",
            options: String.CompareOptions.caseInsensitive
        ),
              let end = remaining[start.upperBound...].range(of: "}}") {
            result += String(remaining[..<start.lowerBound])
            let answer = String(remaining[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            result += reveal ? answer : "[…]"
            remaining = remaining[end.upperBound...]
        }
        result += String(remaining)
        return result
    }
}

struct FlashcardsView: View {
    let cards: [LogseqFlashcard]
    let load: () -> Void
    let review: (LogseqFlashcard, String) -> Void

    @State private var clozeRevealed = false
    @State private var answerRevealed = false

    private var card: LogseqFlashcard? { cards.first }

    var body: some View {
        Group {
            if let card {
                reviewContent(card)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: load)
        .onChange(of: card?.id) { _, _ in
            clozeRevealed = false
            answerRevealed = false
        }
    }

    private func reviewContent(_ card: LogseqFlashcard) -> some View {
        VStack(spacing: 18) {
            HStack {
                Text(verbatim: "Due now")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: "\(cards.count) remaining")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(verbatim: FlashcardPresentation.text(
                        nodes: card.block.markup,
                        fallback: card.block.title,
                        revealCloze: clozeRevealed
                    ))
                    .font(.title2)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("flashcard.question")

                    if answerRevealed, !card.children.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(card.children) { child in
                                Text(verbatim: FlashcardPresentation.text(
                                    nodes: child.markup,
                                    fallback: child.title,
                                    revealCloze: true
                                ))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            }

            reviewControls(card)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 24)
    }

    @ViewBuilder private func reviewControls(_ card: LogseqFlashcard) -> some View {
        let hasCloze = FlashcardPresentation.containsCloze(
            nodes: card.block.markup,
            fallback: card.block.title
        )
        if hasCloze && !clozeRevealed {
            revealButton("Show cloze", identifier: "button.flashcard.show-cloze") {
                clozeRevealed = true
            }
        } else if !answerRevealed {
            revealButton("Show answer", identifier: "button.flashcard.show-answer") {
                answerRevealed = true
            }
        } else {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    ratingButton("Again", rating: "again", color: .red, card: card)
                    ratingButton("Hard", rating: "hard", color: .orange, card: card)
                }
                HStack(spacing: 10) {
                    ratingButton("Good", rating: "good", color: .blue, card: card)
                    ratingButton("Easy", rating: "easy", color: .green, card: card)
                }
            }
        }
    }

    private func revealButton(
        _ title: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(Color.white)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func ratingButton(
        _ title: String,
        rating: String,
        color: Color,
        card: LogseqFlashcard
    ) -> some View {
        Button {
            review(card, rating)
        } label: {
            Text(verbatim: title)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(color)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("button.flashcard.rating.\(rating)")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text(verbatim: "No cards due")
                .font(.title2)
                .fontWeight(.bold)
            Text(verbatim: "Tag a block with #Card to add it to Flashcards.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .accessibilityIdentifier("flashcards.empty")
    }
}
