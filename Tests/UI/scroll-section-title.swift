import UIKit
import SwiftUI
import LUIAppleBackend

@MainActor final class Titles {
    var current: String?
    var changes = 0
}

@main struct ScrollTitleCheck {
    @MainActor static func main() throws {
        let backend = LUIAppleBackend()
        var ops: [[String: Any]] = [
            ["op": "create-node", "id": 1, "kind": "virtual-list"],
            ["op": "set-prop", "id": 1, "property": "style-class", "value": "scroll-section-titles"],
            ["op": "set-prop", "id": 1, "property": "selected", "value": true]]
        for index in 0..<4 {
            let row = 10 + index * 10
            ops += [["op":"create-node", "id":row, "kind":"column"],
                    ["op":"set-prop", "id":row, "property":"height", "value":180],
                    ["op":"insert-child", "parent":1, "child":row, "index":index]]
            let label = row + 1
            ops += [["op":"create-node", "id":label, "kind":"text"],
                    ["op":"set-prop", "id":label, "property":"text", "value": index < 2 ? "Sep 7th" : "Sep 6th"],
                    ["op":"insert-child", "parent":row, "child":label, "index":0]]
            if index % 2 == 0 { ops += [["op":"set-prop", "id":label, "property":"style-class", "value":"scroll-section-title"]] }
        }
        try backend.apply(json: String(decoding: JSONSerialization.data(withJSONObject: ["generation":1,"ops":ops]), as: UTF8.self))
        let titles = Titles()
        let host = UIHostingController(rootView:
            LUISwiftUIRoot(backend: backend, rootID: 1)
                .frame(width: 300, height: 200)
                .onPreferenceChange(LUIScrollTitlePreferenceKey.self) { title in
                    titles.current = title; titles.changes += 1
                })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host; window.makeKeyAndVisible()
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)); host.view.layoutIfNeeded() }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        settle()
        let scroll = descendants(host.view).compactMap { $0 as? UIScrollView }.first!
        var failures = 0
        func check(_ expected: String?, _ label: String) {
            if titles.current != expected { print("FAIL: \(label) expected=\(String(describing: expected)) actual=\(String(describing: titles.current))"); failures += 1 }
        }
        check("Sep 7th", "initial section")
        let initialChanges = titles.changes
        scroll.setContentOffset(CGPoint(x: 0, y: 230), animated: false); settle()
        check("Sep 7th", "rows below the first header keep their section title")
        if titles.changes != initialChanges { print("FAIL: scrolling inside a section must not republish its title"); failures += 1 }
        scroll.setContentOffset(CGPoint(x: 0, y: 365), animated: false); settle()
        check("Sep 6th", "next section")
        scroll.setContentOffset(.zero, animated: false); settle()
        check("Sep 7th", "scrolling back")
        try backend.apply(json: #"{"generation":2,"ops":[{"op":"set-prop","id":1,"property":"selected","value":false}]}"#)
        settle(); check(nil, "hidden pane clears its title")
        guard failures == 0 else { exit(1) }
        print("PASS: section title follows scrolling, stays stable within a section, and clears when hidden")
    }
}
