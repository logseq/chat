import SwiftUI
#if !SKIP && os(iOS)
import UIKit
#endif

struct OutlinerInlineEditor: View {
    let text: String
    let blockID: String
    let desiredCaretUTF16Offset: Int?
    let onTextChange: (String, Int) -> Void
    let onReturn: (String, Int) -> Void
    let onBackspace: (String, Int) -> Void
    let onCaretChange: (Int) -> Void

    var body: some View {
        #if !SKIP && os(iOS)
        NativeOutlinerTextView(
            text: text,
            accessibilityIdentifier: "field.outliner.block.\(blockID)",
            desiredCaretUTF16Offset: desiredCaretUTF16Offset,
            onTextChange: onTextChange,
            onReturn: onReturn,
            onBackspace: onBackspace,
            onCaretChange: onCaretChange
        )
        .frame(minHeight: 24)
        #else
        TextField(
            "Block",
            text: Binding(
                get: { text },
                set: { onTextChange($0, $0.utf16.count) }
            ),
            axis: .vertical
        )
            .font(.body)
            .textFieldStyle(.plain)
            .fixedSize(horizontal: false, vertical: true)
            .onSubmit { onReturn(text, text.utf16.count) }
            .onChange(of: text) { _, value in onCaretChange(value.utf16.count) }
            .accessibilityIdentifier("field.outliner.block.\(blockID)")
        #endif
    }
}

#if !SKIP && os(iOS)
private struct NativeOutlinerTextView: UIViewRepresentable {
    let text: String
    let accessibilityIdentifier: String
    let desiredCaretUTF16Offset: Int?
    let onTextChange: (String, Int) -> Void
    let onReturn: (String, Int) -> Void
    let onBackspace: (String, Int) -> Void
    let onCaretChange: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.adjustsFontForContentSizeCategory = true
        textView.accessibilityIdentifier = accessibilityIdentifier
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.text = text
        textView.selectedRange = NSRange(
            location: min(desiredCaretUTF16Offset ?? text.utf16.count, text.utf16.count),
            length: 0
        )
        DispatchQueue.main.async { [weak textView] in
            guard let textView,
                  InlineEditorFocusPolicy.shouldRequestFocus(
                    isAttachedToWindow: textView.window != nil,
                    isFirstResponder: textView.isFirstResponder
                  ) else { return }
            textView.becomeFirstResponder()
        }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        let isSameBlock = context.coordinator.activeAccessibilityIdentifier
            == accessibilityIdentifier
        switch InlineEditorTextReconciliationPolicy.decision(
            modelText: text,
            localText: context.coordinator.localText,
            isSameBlock: isSameBlock,
            isAwaitingBlockHandoff: context.coordinator.isAwaitingBlockHandoff
        ) {
        case .keepLocal:
            break
        case .acknowledgeLocal:
            context.coordinator.localText = nil
            context.coordinator.isAwaitingBlockHandoff = false
        case .applyModel:
            let wasAwaitingHandoff = context.coordinator.isAwaitingBlockHandoff
            let bufferedTyping = wasAwaitingHandoff
                ? context.coordinator.pendingHandoffTyping : ""
            context.coordinator.pendingHandoffTyping = ""
            context.coordinator.localText = nil
            context.coordinator.isAwaitingBlockHandoff = false
            let selection = textView.selectedRange
            if wasAwaitingHandoff {
                let merged = InlineEditorHandoffMerge.merged(
                    modelText: text,
                    desiredCaretUTF16Offset: desiredCaretUTF16Offset,
                    bufferedTyping: bufferedTyping
                )
                if textView.text != merged.text {
                    textView.text = merged.text
                }
                textView.selectedRange = NSRange(
                    location: merged.caretUTF16Offset,
                    length: 0
                )
                if !bufferedTyping.isEmpty {
                    context.coordinator.localText = merged.text
                    let onTextChange = context.coordinator.parent.onTextChange
                    DispatchQueue.main.async {
                        onTextChange(merged.text, merged.caretUTF16Offset)
                    }
                }
            } else {
                if textView.text != text {
                    textView.text = text
                }
                textView.selectedRange = NSRange(
                    location: min(desiredCaretUTF16Offset ?? selection.location, text.utf16.count),
                    length: 0
                )
            }
        }
        if !isSameBlock {
            #if DEBUG
            print(
                "LogseqChat debug: outliner editor responder handoff "
                    + "from=\(context.coordinator.activeAccessibilityIdentifier) "
                    + "to=\(accessibilityIdentifier) retained=\(textView.isFirstResponder)"
            )
            #endif
            context.coordinator.activeAccessibilityIdentifier = accessibilityIdentifier
        }
        textView.accessibilityIdentifier = accessibilityIdentifier
        if InlineEditorFocusPolicy.shouldRequestFocus(
            isAttachedToWindow: textView.window != nil,
            isFirstResponder: textView.isFirstResponder
        ) {
            textView.becomeFirstResponder()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeOutlinerTextView
        var localText: String?
        var isAwaitingBlockHandoff = false
        var pendingHandoffTyping = ""
        var activeAccessibilityIdentifier: String

        init(parent: NativeOutlinerTextView) {
            self.parent = parent
            activeAccessibilityIdentifier = parent.accessibilityIdentifier
        }

        func textViewDidChange(_ textView: UITextView) {
            localText = textView.text
            parent.onTextChange(textView.text, textView.selectedRange.location)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if textView.text == parent.text {
                parent.onCaretChange(textView.selectedRange.location)
            }
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            if isAwaitingBlockHandoff {
                // The core has not handed the editor to the new block yet;
                // buffer keystrokes so nothing lands in the old block, then
                // merge them into the new block at handoff.
                if replacement.isEmpty {
                    if !pendingHandoffTyping.isEmpty {
                        pendingHandoffTyping.removeLast()
                    }
                } else if replacement != "\n" {
                    pendingHandoffTyping += replacement
                }
                return false
            }
            if replacement == "\n" {
                var submittedText = textView.text ?? ""
                if range.length > 0 {
                    let value = submittedText as NSString
                    let selectionLocation = min(range.location, value.length)
                    let selectionLength = min(range.length, value.length - selectionLocation)
                    submittedText = value.replacingCharacters(
                        in: NSRange(location: selectionLocation, length: selectionLength),
                        with: ""
                    )
                }
                // Leave the text view untouched until the core hands the
                // editor off to the freshly created block; blanking it here
                // makes the current block flash the caret suffix for a frame.
                localText = textView.text
                isAwaitingBlockHandoff = true
                parent.onReturn(submittedText, range.location)
                return false
            }
            if replacement.isEmpty, range.location == 0, range.length == 0 {
                parent.onBackspace(textView.text, range.length)
                return false
            }
            return true
        }
    }
}
#endif
