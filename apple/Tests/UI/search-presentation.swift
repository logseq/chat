import UIKit
import SwiftUI
import OSLog
import LUIAppleBackend

let logger = Logger(subsystem: "com.logseq.chat.tests", category: "Search")

@main struct SearchPresentationCheck {
    static func main() { UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(SearchCheckDelegate.self)) }
}

@MainActor final class SearchCheckDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Task { @MainActor in
            do { try await run() }
            catch { finish("FAIL: \(error)") }
        }
        return true
    }
    private func finish(_ output: String) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("result.txt")
        try? output.write(to: url, atomically: true, encoding: .utf8)
    }
    func run() async throws {
        let registry = LUIAppleExtensionRegistry()
        try LGChatSearchPresentationExtension.register(in: registry)
        let backend = try LUIAppleBackend(extensionRegistry: registry)
        try backend.apply(json: """
        {"generation":1,"ops":[
          {"op":"create-extension","id":1,"identifier":"native-search-presentation","fingerprint":"\(LGChatSearchPresentationExtension.fingerprint)"},
          {"op":"set-extension-prop","id":1,"property":"presented","value":false},
          {"op":"set-extension-prop","id":1,"property":"depth","value":0},
          {"op":"set-extension-prop","id":1,"property":"query","value":""},
          {"op":"set-extension-prop","id":1,"property":"title","value":"Search"},
          {"op":"create-node","id":2,"kind":"column"},
          {"op":"create-node","id":3,"kind":"column"},
          {"op":"insert-child","parent":1,"child":2,"index":0},
          {"op":"insert-child","parent":1,"child":3,"index":1}
        ]}
        """)
        let host = UIHostingController(rootView: NavigationStack {
            LUISwiftUIRoot(backend: backend, rootID: 1)
                .toolbar { ToolbarItem(placement: .topBarLeading) { Text("Journals") } }
        })
        let window = UIWindow(frame: CGRect(x:0,y:0,width:402,height:874))
        self.window = window
        window.rootViewController = host; window.makeKeyAndVisible()
        func step() async { try? await Task.sleep(for: .milliseconds(5)) }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        func input() -> UISearchTextField? {
            descendants(window).compactMap { $0 as? UISearchTextField }.first { $0.isFirstResponder }
        }
        for _ in 0..<40 { await step() }
        var generation = 1
        func present(_ value: Bool) throws {
            generation += 1
            try backend.apply(json: """
            {"generation":\(generation),"ops":[{"op":"set-extension-prop","id":1,"property":"presented","value":\(value)}]}
            """)
        }
        var failures = 0
        var output: [String] = []
        func record(_ message: String) { output.append(message); print(message) }
        for cycle in 0..<3 {
            let start = ProcessInfo.processInfo.systemUptime
            try present(true)
            while input() == nil && ProcessInfo.processInfo.systemUptime - start < 2 { await step() }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            record("Search cycle \(cycle + 1): input ready after \(Int(elapsed * 1000)) ms")
            if input() == nil || elapsed > (cycle == 0 ? 0.8 : 0.45) {
                record("FAIL: search should accept typing while its presentation animates")
                failures += 1
            }
            if window.rootViewController?.presentedViewController == nil {
                record("FAIL: search navigation must be isolated from the app navigation")
                failures += 1
            }
            input()?.insertText("Fixture")
            if input()?.text != "Fixture" { record("FAIL: first typed characters are lost"); failures += 1 }
            // Finish the transition before exercising dismissal and a fresh presentation.
            for _ in 0..<120 { await step() }
            try present(false)
            let closeStart = ProcessInfo.processInfo.systemUptime
            while input() != nil && ProcessInfo.processInfo.systemUptime - closeStart < 2 { await step() }
            if input() != nil { record("FAIL: search did not dismiss"); failures += 1 }
            for _ in 0..<30 { await step() }
        }
        if failures == 0 { record("PASS: search opens ready for input, preserves typing, and reopens after dismissal") }
        finish(output.joined(separator: "\n"))
    }
}
