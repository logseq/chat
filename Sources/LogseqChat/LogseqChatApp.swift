import Foundation
import OSLog
import SwiftUI
import LogseqChatModel

#if os(iOS) && !SKIP
@preconcurrency import BackgroundTasks
#endif

/// A logger for the LogseqChat module.
let logger: Logger = Logger(subsystem: "com.logseq.chat", category: "LogseqChat")

/// The shared top-level view for the app, loaded from the platform-specific App delegates below.
///
/// The default implementation merely loads the `ContentView` for the app and logs a message.
public struct LogseqChatRootView : View {
    public init() {
    }

    public var body: some View {
        ContentView(store: LogseqChatRuntime.shared.store)
            .onAppear {
                DispatchQueue.main.async {
                    LogseqChatAppDelegate.shared.onFirstUIRendered()
                }
            }
            .task {
                logger.info("Skip app logs are viewable in the Xcode console for iOS; Android logs can be viewed in Studio or using adb logcat")
            }
    }
}

@MainActor public final class LogseqChatRuntime {
    public static let shared = LogseqChatRuntime()

    public let store: LogseqChatStore

    private init() {
        self.store = LogseqChatStore { request in
            LogseqChatCore.shared.logseq_chat_call(request)
        }
    }

    public var databasePath: String {
        URL.documentsDirectory
            .appendingPathComponent("logseq-chat.sqlite")
            .path
    }

    public func openStore() {
        store.open(path: databasePath)
    }

    public func refreshFromStoredConnection() async {
        openStore()
        let defaults = UserDefaults.standard
        let baseURL = defaults.string(forKey: "logseq.baseURL") ?? "http://127.0.0.1:8787"
        let token = defaults.string(forKey: "logseq.token") ?? ""
        if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await store.refreshAndSyncForBackground()
        } else {
            await store.configureAndRefreshForBackground(baseURL: baseURL, token: token)
        }
    }
}

public enum LogseqChatBackgroundRefresh {
    public static let identifier = "com.logseq.chat.refresh"

    public static func register() {
        #if os(iOS) && !SKIP
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            handle(task)
        }
        #endif
    }

    public static func schedule(after seconds: TimeInterval = 300) {
        #if os(iOS) && !SKIP
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.debug("Scheduled background refresh")
        } catch {
            logger.error("Could not schedule background refresh: \(String(describing: error), privacy: .public)")
        }
        #endif
    }

    #if os(iOS) && !SKIP
    private static func handle(_ task: BGTask) {
        schedule()
        let refreshTask = Task {
            await LogseqChatRuntime.shared.refreshFromStoredConnection()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            refreshTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }
    #endif
}

/// Global application delegate functions.
///
/// These functions can update a shared observable object to communicate app state changes to interested views.
public final class LogseqChatAppDelegate : Sendable {
    public static let shared = LogseqChatAppDelegate()

    private init() {
    }

    private nonisolated(unsafe) var launchStartedAt: TimeInterval?

    public func onInit() {
        let now = Date().timeIntervalSince1970
        launchStartedAt = now
        print(String(format: "LOGSEQ_LAUNCH_METRIC start=%.6f", now))
        logger.debug("onInit")
    }

    public func onLaunch() {
        reportLaunchMetric("did_finish_launching")
        logger.debug("onLaunch")
    }

    public func onFirstUIRendered() {
        reportLaunchMetric("first_ui_rendered")
    }

    private func reportLaunchMetric(_ name: String) {
        guard let launchStartedAt else { return }
        let elapsedMilliseconds = (Date().timeIntervalSince1970 - launchStartedAt) * 1_000.0
        print(String(format: "LOGSEQ_LAUNCH_METRIC %@_ms=%.3f", name, elapsedMilliseconds))
    }

    public func onResume() {
        logger.debug("onResume")
    }

    public func onPause() {
        logger.debug("onPause")
    }

    public func onStop() {
        logger.debug("onStop")
    }

    public func onDestroy() {
        logger.debug("onDestroy")
    }

    public func onLowMemory() {
        logger.debug("onLowMemory")
    }
}
