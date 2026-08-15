import Foundation
import OSLog
import SwiftUI
import LogseqChatModel

#if !SKIP
import Amplify
import Authenticator
import AWSCognitoAuthPlugin
#endif

#if os(iOS) && !SKIP
@preconcurrency import BackgroundTasks
#endif

/// A logger for the LogseqChat module.
let logger: os.Logger = os.Logger(subsystem: "com.logseq.chat", category: "LogseqChat")

/// The shared top-level view for the app, loaded from the platform-specific App delegates below.
///
/// The default implementation merely loads the `ContentView` for the app and logs a message.
public struct LogseqChatRootView : View {
    public init() {
        #if !SKIP
        LogseqAmplifyAuth.configure()
        #endif
    }

    public var body: some View {
        #if !SKIP
        Authenticator { _ in
            appContent
        }
        .hidesSignUpButton()
        #else
        appContent
        #endif
    }

    private var appContent: some View {
        ContentView(
            store: LogseqChatRuntime.shared.store,
            authentication: LogseqChatRuntime.shared.authentication
        )
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

#if !SKIP
private enum LogseqAmplifyAuth {
    private static let configureOnce: Void = {
        let configuration = LogseqCognitoConfiguration.load()
        let outputs = AmplifyOutputsData(
            auth: .init(
                awsRegion: configuration.region,
                userPoolId: configuration.userPoolId,
                userPoolClientId: configuration.appClientId,
                passwordPolicy: .init(
                    minLength: 8,
                    requireNumbers: true,
                    requireLowercase: true,
                    requireUppercase: true,
                    requireSymbols: true
                ),
                standardRequiredAttributes: [.email],
                userVerificationTypes: [.email]
            )
        )
        do {
            try Amplify.add(plugin: AWSCognitoAuthPlugin())
            try Amplify.configure(outputs)
        } catch {
            logger.error("Could not configure Amplify Auth: \(String(describing: error), privacy: .public)")
        }
    }()

    static func configure() {
        _ = configureOnce
    }
}
#endif

@MainActor public final class LogseqChatRuntime {
    public static let shared = LogseqChatRuntime()

    public let store: LogseqChatStore
    public let authentication: LogseqAuthenticationStore

    private init() {
        self.store = LogseqChatStore { request in
            LogseqChatCore.shared.logseq_chat_call(request)
        }
        let configuration = LogseqCognitoConfiguration.load()
        self.authentication = LogseqAuthenticationStore(
            provider: CognitoAuthProvider(
                region: configuration.region,
                userPoolId: configuration.userPoolId,
                appClientId: configuration.appClientId
            )
        )
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
        let graphID = defaults.string(forKey: "logseq.selectedGraphId")
        guard let token = try? await authentication.accessToken() else { return }
        await store.configureAndRefreshForBackground(baseURL: baseURL, token: token, graphID: graphID)
    }
}

struct LogseqCognitoConfiguration: Decodable {
    let region: String
    let userPoolId: String
    let appClientId: String

    static func load() -> LogseqCognitoConfiguration {
        guard
            let url = Bundle.module.url(forResource: "logseq-auth", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let configuration = try? JSONDecoder().decode(LogseqCognitoConfiguration.self, from: data)
        else {
            return LogseqCognitoConfiguration(region: "", userPoolId: "", appClientId: "")
        }
        return configuration
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
