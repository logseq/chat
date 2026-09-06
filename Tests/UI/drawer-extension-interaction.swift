import SwiftUI
@testable import LUIAppleBackend

@main
struct DrawerExtensionCheck {
    @MainActor static func main() throws {
        let registry = LUIAppleExtensionRegistry()
        try registry.register(LUIAppleExtension(
            identifier: "test-host", fingerprint: "test-host-v1",
            acceptsStandardChildren: true,
            events: [.init(name: "state-change")]
        ) { _ in AnyView(EmptyView()) })
        let backend = try LUIAppleBackend(extensionRegistry: registry)
        try backend.apply(json: """
        {"generation":1,"ops":[
          {"op":"create-node","id":1,"kind":"root"},
          {"op":"create-node","id":10,"kind":"column"},
          {"op":"insert-child","parent":1,"child":10,"index":0},
          {"op":"create-node","id":2,"kind":"drawer"},
          {"op":"create-node","id":3,"kind":"column"},
          {"op":"create-node","id":4,"kind":"column"},
          {"op":"create-extension","id":5,"identifier":"test-host","fingerprint":"test-host-v1"},
          {"op":"create-node","id":6,"kind":"button"},
          {"op":"create-node","id":7,"kind":"button"},
          {"op":"set-prop","id":6,"property":"text","value":"Hosted button"},
          {"op":"set-prop","id":7,"property":"text","value":"Outside button"},
          {"op":"insert-child","parent":10,"child":2,"index":0},
          {"op":"insert-child","parent":10,"child":7,"index":1},
          {"op":"insert-child","parent":2,"child":3,"index":0},
          {"op":"insert-child","parent":2,"child":4,"index":1},
          {"op":"insert-child","parent":3,"child":5,"index":0},
          {"op":"insert-child","parent":5,"child":6,"index":0}
        ]}
        """)
        let context = LUIAppleExtensionViewContext(nodeID: 5, backend: backend)
        precondition(context.isUserInteractionEnabled, "An idle extension must allow actions")
        var count = 0
        backend.onEvent = { _ in count += 1 }
        try backend.performPress(node: 6)
        precondition(count == 1, "An idle hosted button must work")
        backend.setDrawerInteractionLocked(true, node: 2)
        precondition(!context.isUserInteractionEnabled, "Extension links must observe the drawer lock")
        try backend.performPress(node: 6)
        guard count == 1 else {
            print("FAIL: a button hosted inside an extension bypassed its drawer lock")
            exit(1)
        }
        try backend.performPress(node: 7)
        precondition(count == 2, "An unrelated control must remain interactive")
        try backend.performExtensionEvent(node: 5, name: "state-change", values: [:])
        precondition(count == 3, "State updates must not be discarded during a drag")
        backend.setDrawerInteractionLocked(false, node: 2)
        precondition(context.isUserInteractionEnabled, "Extension links must resume after unlock")
        try backend.performPress(node: 6)
        precondition(count == 4, "Hosted interaction must resume after the drag")
        print("PASS: extension ancestry, unrelated controls, state updates, and unlock")
    }
}
