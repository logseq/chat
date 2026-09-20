import UIKit
import SwiftUI
import LUIAppleBackend

@main
struct Check {
    @MainActor static func main() throws {
        let backend = LUIAppleBackend()
        try backend.apply(json: #"{"generation":1,"ops":[{"op":"create-node","id":1,"kind":"button"},{"op":"set-prop","id":1,"property":"text","value":"•"},{"op":"set-prop","id":1,"property":"width","value":24},{"op":"set-prop","id":1,"property":"height","value":24},{"op":"set-prop","id":1,"property":"variant","value":"ghost"},{"op":"set-prop","id":1,"property":"style-class","value":"body-line"}]}"#)
        var failures = 0
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility5] {
            let control = UIHostingController(rootView: LUISwiftUIRoot(backend: backend, rootID: 1).fixedSize(horizontal: false, vertical: true).environment(\.dynamicTypeSize, size))
            let text = UIHostingController(rootView: Text(" ").font(.body).frame(minHeight: 24).environment(\.dynamicTypeSize, size))
            let expected = text.sizeThatFits(in: CGSize(width: 24, height: 200)).height
            let actual = control.sizeThatFits(in: CGSize(width: 24, height: 200)).height
            let passed = abs(expected - actual) < 0.34
            print("\(passed ? "PASS" : "FAIL"): \(size) firstLine=\(expected) control=\(actual)")
            if !passed { failures += 1 }
        }
        if failures > 0 { exit(1) }
    }
}
