import SwiftUI

@main struct SearchResultTextCheck {
    static func main() {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if !condition { print("FAIL: \(message)"); failures += 1 }
        }
        func matches(_ text: AttributedString) -> [String] {
            text.runs.compactMap { run in
                guard run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true else { return nil }
                return String(text[run.range].characters)
            }
        }
        let accents = LUITextHighlight.preview("Café CAFÉ cafe", query: "cafe")
        check(matches(accents) == ["Café", "CAFÉ", "cafe"], "matches ignore case and diacritics")
        let literal = LUITextHighlight.preview("[draft] release", query: "[draft]")
        check(matches(literal) == ["[draft]"], "query punctuation is literal")
        let unicode = LUITextHighlight.preview("🙂 发布计划: 提前发布", query: "发布")
        check(String(unicode.characters) == "🙂 发布计划: 提前发布", "Unicode text is preserved")
        check(matches(unicode) == ["发布", "发布"], "Unicode matches retain grapheme boundaries")
        let words = LUITextHighlight.preview("Plan the release", query: "plan release")
        check(matches(words) == ["Plan", "release"], "separate query words are emphasized")
        let long = LUITextHighlight.preview(String(repeating: "prefix ", count: 100) + "needle " + String(repeating: "tail ", count: 100), query: "needle")
        let preview = String(long.characters)
        check(preview.count <= 242 && preview.hasPrefix("…") && preview.hasSuffix("…"), "long results use a bounded context snippet")
        check(matches(long) == ["needle"], "snippets keep the matching term visible")
        let empty = LUITextHighlight.preview("A short title", query: " \n ")
        check(matches(empty).isEmpty && String(empty.characters) == "A short title", "an empty query preserves text")
        guard failures == 0 else { exit(1) }
        print("PASS: readable search snippets, Unicode, literal queries, and match emphasis")
    }
}
