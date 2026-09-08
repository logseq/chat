import AppKit
import SwiftUI
@testable import LUIAppleBackend

@main
struct DrawerLazyPanelCheck {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        var failures: [String] = []
        for initiallyOpen in [false, true] {
            var appearances = 0
            var constructions = 0
            let registry = LUIAppleExtensionRegistry()
            try registry.register(LUIAppleExtension(
                identifier: "panel-probe", fingerprint: "panel-probe-v1"
            ) { _ in
                constructions += 1
                return AnyView(Text("Sidebar").onAppear { appearances += 1 })
            })
            let backend = try LUIAppleBackend(extensionRegistry: registry)
            try backend.apply(json: """
            {"generation":1,"ops":[
              {"op":"create-node","id":1,"kind":"root"},
              {"op":"create-node","id":2,"kind":"drawer"},
              {"op":"create-node","id":3,"kind":"text"},
              {"op":"set-prop","id":3,"property":"text","value":"Journal"},
              {"op":"set-prop","id":2,"property":"selected","value":\(initiallyOpen)},
              {"op":"create-extension","id":4,"identifier":"panel-probe","fingerprint":"panel-probe-v1"},
              {"op":"insert-child","parent":1,"child":2,"index":0},
              {"op":"insert-child","parent":2,"child":3,"index":0},
              {"op":"insert-child","parent":2,"child":4,"index":1}
            ]}
            """)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 700),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: LUISwiftUIRoot(backend: backend, rootID: 1))
            window.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            if initiallyOpen {
                if appearances != 1 { failures.append("Initially open panel must appear immediately") }
            } else if constructions != 0 || appearances != 0 {
                failures.append("Closed drawer eagerly constructed its panel (builds=\(constructions), appearances=\(appearances))")
            }
            for (index, selected) in [true, false, true].enumerated() {
                try backend.apply(json: """
                {"generation":\(index + 2),"ops":[
                  {"op":"set-prop","id":2,"property":"selected","value":\(selected)}
                ]}
                """)
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                if appearances != 1 {
                    failures.append("Panel must mount once and retain its state through close/reopen")
                }
            }
            window.close()
        }
        if !failures.isEmpty {
            failures.forEach { print("FAIL: \($0)") }
            exit(1)
        }
        print("PASS: deferred panel construction, initially open drawer, retained close/reopen")
    }
}
