import UIKit

@main
struct OutlinerCaretLayoutCheck {
    @MainActor static func main() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        var failures = 0
        var checks = 0
        for source in ["", "Hello world", "First line\nSecond line\nThird line", "First line\n", "A longer paragraph with enough text to wrap onto multiple lines and preserve the caret at the end.", "中文内容 😀 第二行\n最后一行"] {
            for width: CGFloat in [300, 160] {
                func make(compact: Bool) -> UITextView {
                    let view = compact ? OutlinerLayoutTextView() : UITextView()
                    view.font = .preferredFont(forTextStyle: .body)
                    view.isScrollEnabled = false
                    view.textContainer.lineFragmentPadding = 0
                    if compact { OutlinerNativeTextMeasurement.configureTextContainer(view) }
                    let inset = max(0, (24 - view.font!.lineHeight) / 2)
                    view.textContainerInset = UIEdgeInsets(top: inset, left: 0, bottom: inset, right: 0)
                    view.text = source
                    let height = compact
                        ? max(24, OutlinerNativeTextMeasurement.size(text: source, font: view.font!, width: width, verticalInset: inset, scale: 3).height)
                        : view.sizeThatFits(CGSize(width: width, height: 10000)).height
                    view.frame = CGRect(x: 40, y: 200, width: width, height: height)
                    root.view.addSubview(view)
                    view.selectedRange = NSRange(location: source.utf16.count, length: 0)
                    view.becomeFirstResponder()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    view.layoutIfNeeded()
                    return view
                }
                let reference = make(compact: false)
                let expected = reference.caretRect(for: reference.selectedTextRange!.end)
                reference.resignFirstResponder()
                reference.removeFromSuperview()
                let compact = make(compact: true)
                let actual = compact.caretRect(for: compact.selectedTextRange!.end)
                let passed = abs(actual.minX - expected.minX) < 0.34 && abs(actual.minY - expected.minY) < 0.34 && actual.width > 0 && actual.height > 10
                checks += 1
                if !passed {
                    failures += 1
                    print("FAIL: width=\(width) text=\(source.debugDescription) expected=\(expected) actual=\(actual)")
                }
                compact.resignFirstResponder()
                compact.removeFromSuperview()
            }
        }
        guard failures == 0 else { exit(1) }
        print("PASS: \(checks) compact editor caret comparisons")
    }
}
