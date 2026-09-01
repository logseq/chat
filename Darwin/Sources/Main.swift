import SwiftUI
import LogseqChat
#if os(iOS)
import AppIntents
#endif

private typealias AppRootView = LogseqChatRootView
private typealias AppDelegate = LogseqChatAppDelegate

/// The entry point to the app simply loads the App implementation from SPM module.
@main struct AppMain: App {
    @AppDelegateAdaptor(AppMainDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            switch newPhase {
            case .active:
                AppDelegate.shared.onResume()
            case .inactive:
                AppDelegate.shared.onPause()
            case .background:
                AppDelegate.shared.onStop()
                LogseqChatBackgroundRefresh.syncNow()
                LogseqChatBackgroundRefresh.schedule()
            @unknown default:
                print("unknown app phase: \(newPhase)")
            }
        }
    }
}

#if canImport(UIKit)
typealias AppDelegateAdaptor = UIApplicationDelegateAdaptor
typealias AppMainDelegateBase = UIApplicationDelegate
typealias AppType = UIApplication
#elseif canImport(AppKit)
typealias AppDelegateAdaptor = NSApplicationDelegateAdaptor
typealias AppMainDelegateBase = NSApplicationDelegate
typealias AppType = NSApplication
#endif

@MainActor final class AppMainDelegate: NSObject, AppMainDelegateBase {
    let application = AppType.shared

    #if canImport(UIKit)
    func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        AppDelegate.shared.onInit()
        return true
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        AppDelegate.shared.onLaunch()
        LogseqChatBackgroundRefresh.register()
        LogseqChatBackgroundRefresh.schedule()
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        AppDelegate.shared.onDestroy()
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        AppDelegate.shared.onLowMemory()
    }

    // Support notification token retrieval from the app runtime.

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: NSNotification.Name("didRegisterForRemoteNotificationsWithDeviceToken"), object: application, userInfo: ["deviceToken": deviceToken])
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        NotificationCenter.default.post(name: NSNotification.Name("didFailToRegisterForRemoteNotificationsWithError"), object: application, userInfo: ["error": error])
    }
    #elseif canImport(AppKit)
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppDelegate.shared.onInit()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared.onLaunch()
    }

    func applicationWillTerminate(_ application: Notification) {
        AppDelegate.shared.onDestroy()
    }
    #endif

}

#if os(iOS)
@available(iOS 17.0, *)
struct CaptureToJournalIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture to Journal"
    static let description = IntentDescription("Add text to today's Logseq journal.")
    static let openAppWhenRun = true

    @Parameter(
        title: "Text",
        requestValueDialog: IntentDialog("What would you like to capture?")
    )
    var text: String

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard ShortcutCapture.enqueue(text) else {
            return .result(dialog: "Enter some text to capture.")
        }
        LogseqChatRuntime.shared.processSharedCaptures()
        return .result(dialog: "Added to today's journal.")
    }
}

@available(iOS 17.0, *)
struct LogseqAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureToJournalIntent(),
            phrases: [
                "Capture in \(.applicationName)",
                "Add to my \(.applicationName) journal"
            ],
            shortTitle: "Capture",
            systemImageName: "square.and.pencil"
        )
    }
}
#endif
