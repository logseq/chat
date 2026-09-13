import AppKit
import SwiftUI
@testable import LUIAppleBackend

@main
struct ComposerFooterLayoutCheck {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.regular)
        var footerBottom: CGFloat = 0
        let registry = LUIAppleExtensionRegistry()
        try registry.register(LUIAppleExtension(identifier: "footer-probe", fingerprint: "footer-probe") { _ in
            AnyView(Color.clear.frame(width: 40, height: 40)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY }
                action: { footerBottom = $0 })
        })
        let backend = try LUIAppleBackend(extensionRegistry: registry)
        try backend.apply(json: """
        {"generation":1,"ops":[
          {"op":"create-node","id":1,"kind":"column"},
          {"op":"set-prop","id":1,"property":"main","value":"end"},
          {"op":"set-prop","id":1,"property":"padding-vertical","value":8},
          {"op":"create-node","id":2,"kind":"textarea"},
          {"op":"set-prop","id":2,"property":"style-class","value":"composer-input"},
          {"op":"set-prop","id":2,"property":"min-height","value":36},
          {"op":"set-prop","id":2,"property":"text","value":"First"},
          {"op":"create-node","id":3,"kind":"row"},
          {"op":"set-prop","id":3,"property":"height","value":44},
          {"op":"create-extension","id":4,"identifier":"footer-probe","fingerprint":"footer-probe"},
          {"op":"insert-child","parent":1,"child":2,"index":0},
          {"op":"insert-child","parent":1,"child":3,"index":1},
          {"op":"insert-child","parent":3,"child":4,"index":0}
        ]}
        """)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Color.clear.overlay(alignment: .bottom) {
            LUIAnyNodeView(nodeID: 1, backend: backend)
                .frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
        })
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let baseline = footerBottom
        precondition(baseline > 0, "Footer must be measured")
        for (index, lines) in [3, 6, 12, 1].enumerated() {
            let text = Array(repeating: "A line of capture text", count: lines).joined(separator: "\n")
            let json = try JSONSerialization.data(withJSONObject: ["generation": index + 2, "ops": [
                ["op": "set-prop", "id": 2, "property": "text", "value": text]
            ]])
            try backend.apply(json: String(decoding: json, as: UTF8.self))
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            precondition(abs(footerBottom - baseline) < 1, "Footer moved with \(lines) lines")
        }
        window.close()
        print("PASS: rendered Capture footer stays anchored with 1, 3, 6 and 12 lines")
    }
}
