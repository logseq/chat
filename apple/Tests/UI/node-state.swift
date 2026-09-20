import UIKit
import SwiftUI
import LUIAppleBackend

@main struct NodeStateCheck {
    static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(NodeStateDelegate.self))
    }
}

@MainActor final class NodeStateDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Task {
            do { try await run() }
            catch { finish("FAIL: \(error)") }
        }
        return true
    }

    func finish(_ output: String) {
        let url = URL.documentsDirectory.appendingPathComponent("result.txt")
        try? output.write(to: url, atomically: true, encoding: .utf8)
    }

    func run() async throws {
        let backend = LUIAppleBackend()
        try backend.apply(json: """
        {"generation":1,"ops":[
          {"op":"create-node","id":1,"kind":"root"},
          {"op":"create-node","id":2,"kind":"column"},
          {"op":"create-node","id":3,"kind":"text-field"},
          {"op":"set-prop","id":3,"property":"text","value":"Draft"},
          {"op":"create-node","id":4,"kind":"text"},
          {"op":"set-prop","id":4,"property":"text","value":"Before"},
          {"op":"insert-child","parent":1,"child":2,"index":0},
          {"op":"insert-child","parent":2,"child":3,"index":0},
          {"op":"insert-child","parent":2,"child":4,"index":1}
        ]}
        """)
        let host = UIHostingController(rootView: LUISwiftUIRoot(backend: backend, rootID: 1))
        let window = UIWindow(frame: UIScreen.main.bounds)
        self.window = window
        window.rootViewController = host
        window.makeKeyAndVisible()
        func settle() async { try? await Task.sleep(for: .milliseconds(250)) }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        func input() -> UITextField? { descendants(window).compactMap { $0 as? UITextField }.first }
        await settle()
        guard let field = input() else { finish("FAIL: missing text field"); return }
        field.becomeFirstResponder()
        await settle()
        field.insertText(" local")
        await settle()
        let draft = field.text
        let selection = field.selectedTextRange.map { field.offset(from: field.beginningOfDocument, to: $0.start) }
        try backend.apply(json: """
        {"generation":2,"ops":[
          {"op":"set-prop","id":4,"property":"text","value":"After"},
          {"op":"set-prop","id":2,"property":"gap","value":12},
          {"op":"create-node","id":5,"kind":"heading"},
          {"op":"set-prop","id":5,"property":"text","value":"Inserted"},
          {"op":"insert-child","parent":2,"child":5,"index":0}
        ]}
        """)
        await settle()
        guard input() === field, field.isFirstResponder, field.text == draft,
              field.selectedTextRange.map({ field.offset(from: field.beginningOfDocument, to: $0.start) }) == selection else {
            finish("FAIL: sibling updates changed input identity, focus, draft, or caret"); return
        }
        field.resignFirstResponder()
        try backend.apply(json: """
        {"generation":3,"ops":[{"op":"set-prop","id":3,"property":"text","value":"Remote"}]}
        """)
        await settle()
        guard input() === field, field.text == "Remote" else {
            finish("FAIL: authoritative input update did not reconcile"); return
        }
        finish("PASS: node identity, local draft, focus, caret, sibling updates, and authoritative reconciliation")
    }
}
