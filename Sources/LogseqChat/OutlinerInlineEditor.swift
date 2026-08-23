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
            blockID: blockID,
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
@MainActor
private final class OutlinerNativeEditorSession {
    static let shared = OutlinerNativeEditorSession()
    let textView = FocusRetainingTextView()
    private let parkingView = UIView(frame: CGRect(x: -2, y: -2, width: 1, height: 1))
    fileprivate var activeBlockID: String?
    fileprivate var localText: String?
    fileprivate var isAwaitingBlockHandoff = false
    fileprivate var pendingHandoffTyping = ""

    init() {
        parkingView.clipsToBounds = true
        parkingView.alpha = 0.01
    }

    func attach(to container: UIView) {
        guard textView.superview !== container else { return }
        textView.removeFromSuperview()
        container.addSubview(textView)
        textView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            textView.topAnchor.constraint(equalTo: container.topAnchor),
            textView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        parkingView.removeFromSuperview()
    }

    func parkForStructuralEdit() {
        guard InlineEditorResponderContinuityPolicy.shouldPark(
            isFirstResponder: textView.isFirstResponder,
            isStructuralEdit: true
        ), let window = textView.window else { return }
        if parkingView.superview !== window {
            parkingView.removeFromSuperview()
            window.addSubview(parkingView)
        }
        textView.removeFromSuperview()
        parkingView.addSubview(textView)
        textView.translatesAutoresizingMaskIntoConstraints = true
        textView.frame = parkingView.bounds
    }
}

private struct NativeOutlinerTextView: UIViewRepresentable {
    let blockID: String
    let text: String
    let accessibilityIdentifier: String
    let desiredCaretUTF16Offset: Int?
    let onTextChange: (String, Int) -> Void
    let onReturn: (String, Int) -> Void
    let onBackspace: (String, Int) -> Void
    let onCaretChange: (Int) -> Void

    private var session: OutlinerNativeEditorSession { .shared }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let textView = session.textView
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.adjustsFontForContentSizeCategory = true
        applyWritingAssistance(to: textView)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        let textView = session.textView
        textView.delegate = context.coordinator
        applyWritingAssistance(to: textView)
        context.coordinator.parent = self
        let isSameBlock = session.activeBlockID == blockID
        switch InlineEditorTextReconciliationPolicy.decision(
            modelText: text,
            localText: session.localText,
            isSameBlock: isSameBlock,
            isAwaitingBlockHandoff: session.isAwaitingBlockHandoff
        ) {
        case .keepLocal:
            break
        case .acknowledgeLocal:
            session.localText = nil
            session.isAwaitingBlockHandoff = false
        case .applyModel:
            let wasAwaitingHandoff = session.isAwaitingBlockHandoff
            let bufferedTyping = wasAwaitingHandoff
                ? session.pendingHandoffTyping : ""
            session.pendingHandoffTyping = ""
            session.localText = nil
            session.isAwaitingBlockHandoff = false
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
                    session.localText = merged.text
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
                    + "from=\(session.activeBlockID ?? "none") "
                    + "to=\(accessibilityIdentifier) retained=\(textView.isFirstResponder)"
            )
            #endif
            session.activeBlockID = blockID
        }
        textView.accessibilityIdentifier = accessibilityIdentifier
        session.attach(to: container)
        if InlineEditorFocusPolicy.shouldRequestFocus(
            isAttachedToWindow: textView.window != nil,
            isFirstResponder: textView.isFirstResponder
        ) {
            textView.requestFocusWhenAttached()
        }
    }

    private func applyWritingAssistance(to textView: UITextView) {
        let defaults = UserDefaults.standard
        let spellCheck = defaults.object(forKey: "logseq.editor.spellCheck") as? Bool ?? true
        let autoCorrection = defaults.object(forKey: "logseq.editor.autoCorrection") as? Bool ?? true
        textView.spellCheckingType = spellCheck ? .yes : .no
        textView.autocorrectionType = autoCorrection ? .yes : .no
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UIView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return session.textView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeOutlinerTextView

        init(parent: NativeOutlinerTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.session.localText = textView.text
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
            if parent.session.isAwaitingBlockHandoff {
                // Structure events are serialized and rebound to the latest
                // editor by the store. Forward them immediately so fast
                // Return/Backspace input is never swallowed during handoff.
                if replacement == "\n" {
                    parent.onReturn(textView.text, range.location)
                } else if replacement.isEmpty, range.location == 0, range.length == 0 {
                    parent.onBackspace(textView.text, range.length)
                } else if replacement.isEmpty {
                    if !parent.session.pendingHandoffTyping.isEmpty {
                        parent.session.pendingHandoffTyping.removeLast()
                    }
                } else {
                    parent.session.pendingHandoffTyping += replacement
                }
                return false
            }
            if let deletion = InlineEditorPairDeletion.deletingEmptyNodeReference(
                from: textView.text ?? "",
                range: range,
                replacementText: replacement
            ) {
                textView.text = deletion.text
                textView.selectedRange = NSRange(
                    location: deletion.caretUTF16Offset,
                    length: 0
                )
                parent.session.localText = deletion.text
                parent.onTextChange(deletion.text, deletion.caretUTF16Offset)
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
                parent.session.localText = textView.text
                parent.session.isAwaitingBlockHandoff = true
                parent.session.parkForStructuralEdit()
                parent.onReturn(submittedText, range.location)
                return false
            }
            if replacement.isEmpty, range.location == 0, range.length == 0 {
                parent.session.isAwaitingBlockHandoff = true
                parent.session.parkForStructuralEdit()
                parent.onBackspace(textView.text, range.length)
                return false
            }
            return true
        }
    }
}

private final class FocusRetainingTextView: UITextView {
    private var focusPending = false

    func requestFocusWhenAttached() {
        guard !isFirstResponder else {
            focusPending = false
            return
        }
        focusPending = true
        fulfillPendingFocus()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        fulfillPendingFocus()
    }

    private func fulfillPendingFocus() {
        guard focusPending, window != nil else { return }
        if becomeFirstResponder() {
            focusPending = false
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusPending, self.window != nil else { return }
            if self.becomeFirstResponder() {
                self.focusPending = false
            }
        }
    }
}
#endif
