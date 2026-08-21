import Foundation
import OSLog
import SwiftUI
import LogseqChatModel

#if !SKIP && AppleAuth
import Amplify
import Authenticator
import AWSCognitoAuthPlugin
#endif

#if os(iOS) && !SKIP
@preconcurrency import BackgroundTasks
import UIKit
#endif

/// A logger for the LogseqChat module.
let logger: os.Logger = os.Logger(subsystem: "com.logseq.chat", category: "LogseqChat")

/// The shared top-level view for the app, loaded from the platform-specific App delegates below.
///
/// The default implementation merely loads the `ContentView` for the app and logs a message.
public struct LogseqChatRootView : View {
    @State private var authentication = LogseqChatRuntime.shared.authentication

    public init() {
    }

    public var body: some View {
        #if !SKIP && AppleAuth
        ZStack {
            appContent
            if authentication.state == .signedOut {
                Authenticator { _ in
                    EmptyView()
                }
                .hidesSignUpButton()
            }
        }
        #else
        appContent
        #endif
    }

    private var appContent: some View {
        ContentView(
            store: LogseqChatRuntime.shared.store,
            authentication: LogseqChatRuntime.shared.authentication,
            syncCoordinator: LogseqChatRuntime.shared.syncCoordinator
        )
            .onAppear {
                DispatchQueue.main.async {
                    LogseqChatAppDelegate.shared.onFirstUIRendered()
                }
            }
            .task {
                logger.info("Skip app logs are viewable in the Xcode console for iOS; Android logs can be viewed in Studio or using adb logcat")
            }
            .onOpenURL { url in
                LogseqChatRuntime.shared.acceptSharedCaptureURL(url)
            }
    }
}

#if !SKIP && AppleAuth
@MainActor enum LogseqAmplifyAuth {
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
    let syncCoordinator = GraphSyncCoordinator()
    private struct LocalLaunchResult: Sendable {
        let catalogResponse: String
        let graphResponse: String?
        let isEncrypted: Bool?
    }
    private var localLaunchTask: Task<LocalLaunchResult, Never>?
    private var didApplyLocalLaunchResult = false
    private var sharedCaptureTask: Task<Void, Never>?

    private init() {
        try? FileManager.default.removeItem(
            at: URL.documentsDirectory.appendingPathComponent("cached-home-snapshot.json")
        )
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

    public func startLocalLaunchLoad() {
        guard localLaunchTask == nil else { return }
        let graphID = UserDefaults.standard.string(forKey: "logseq.selectedGraphId") ?? ""
        let databasePath = databasePath
        let baseURL = UserDefaults.standard.string(forKey: "logseq.baseURL")
            ?? "http://127.0.0.1:8787"
        localLaunchTask = Task.detached(priority: .userInitiated) {
            LogseqChatAppDelegate.shared.reportLaunchStage("local_load_started")
            func configureGraph() async {
                let payloadObject: [String: Any] = [
                    "baseUrl": baseURL,
                    "graphId": graphID,
                    "token": ""
                ]
                guard let data = try? JSONSerialization.data(withJSONObject: payloadObject),
                      let payload = String(data: data, encoding: .utf8) else { return }
                _ = await LogseqChatStore.callForLaunch(
                    LogseqChatRPCRequest(
                        method: "dispatch",
                        params: LogseqChatRPCParams(action: "configure", payload: payload)
                    )
                )
                LogseqChatAppDelegate.shared.reportLaunchStage("graph_configured")
            }

            func openGraph(isEncrypted: Bool) async -> String? {
                guard !graphID.isEmpty else { return nil }
                let graphDirectory = LogseqGraphLocalStorage.directoryURL(
                    databasePath: databasePath,
                    graphID: graphID
                )
                let payloadObject: [String: Any] = [
                    "graphId": graphID,
                    "activePath": graphDirectory.appendingPathComponent("graph.sqlite").path,
                    "checkpointPath": graphDirectory.appendingPathComponent("sync.checkpoint").path,
                    "isEncrypted": isEncrypted
                ]
                guard let payloadData = try? JSONSerialization.data(withJSONObject: payloadObject),
                      let payload = String(data: payloadData, encoding: .utf8) else { return nil }
                LogseqChatAppDelegate.shared.reportLaunchStage("open_graph_started")
                let response = await LogseqChatStore.callForLaunch(
                    LogseqChatRPCRequest(
                        method: "dispatch",
                        params: LogseqChatRPCParams(action: "openGraph", payload: payload)
                    )
                )
                LogseqChatAppDelegate.shared.reportLaunchStage("open_graph_returned")
                return response
            }

            let catalogResponse = await LogseqChatStore.callForLaunch(
                LogseqChatRPCRequest(
                    method: "open",
                    params: LogseqChatRPCParams(action: nil, path: databasePath)
                )
            )
            LogseqChatAppDelegate.shared.reportLaunchStage("catalog_opened")
            guard !graphID.isEmpty,
                  let catalogData = catalogResponse.data(using: .utf8),
                  let catalog = try? JSONDecoder().decode(
                    LogseqChatRPCResponse.self,
                    from: catalogData
                  ) else {
                return LocalLaunchResult(
                    catalogResponse: catalogResponse,
                    graphResponse: nil,
                    isEncrypted: nil
                )
            }
            let isEncrypted = catalog.result?.graphs?
                .first(where: { $0.id == graphID })?.isEncrypted ?? false
            await configureGraph()
            let graphResponse = await openGraph(isEncrypted: isEncrypted)
            return LocalLaunchResult(
                catalogResponse: catalogResponse,
                graphResponse: graphResponse,
                isEncrypted: isEncrypted
            )
        }
        Task { [weak self] in
            await self?.applyLocalLaunchResultWhenReady()
        }
    }

    public func waitForLocalLaunchLoad() async {
        startLocalLaunchLoad()
        await applyLocalLaunchResultWhenReady()
    }

    private func applyLocalLaunchResultWhenReady() async {
        guard !didApplyLocalLaunchResult, let result = await localLaunchTask?.value else { return }
        didApplyLocalLaunchResult = true
        if let isEncrypted = result.isEncrypted {
            UserDefaults.standard.set(isEncrypted, forKey: "logseq.selectedGraphEncrypted")
        }
        if let graphResponse = result.graphResponse {
            store.applyLaunchResponse(
                graphResponse,
                actionName: "openGraph",
                databasePath: databasePath
            )
            LogseqChatAppDelegate.shared.reportLaunchStage("store_opened")
            LogseqChatAppDelegate.shared.reportLaunchStage("graph_loaded")
        } else {
            store.applyLaunchResponse(
                result.catalogResponse,
                actionName: "open",
                databasePath: databasePath
            )
            LogseqChatAppDelegate.shared.reportLaunchStage("store_opened")
        }
        drainSharedCapturesIfReady()
    }

    public func acceptSharedCaptureURL(_ url: URL) {
        guard let deepLink = LogseqDeepLink(url) else { return }
        switch deepLink {
        case .captureText(let text):
            SharedCaptureInbox.shared.enqueueText(text)
            drainSharedCapturesIfReady()
        case .openCapture:
            store.requestCapture()
        case .openJournal:
            store.clearSelectedPage()
        }
    }

    public func acceptSharedText(_ text: String) {
        SharedCaptureInbox.shared.enqueueText(text)
        drainSharedCapturesIfReady()
    }

    public func acceptSharedAsset(
        title: String,
        assetType: String,
        size: Int,
        checksum: String,
        stagedFileName: String
    ) {
        let asset = SharedCaptureAsset(
            title: title,
            assetType: assetType,
            size: size,
            checksum: checksum,
            stagedFileName: stagedFileName
        )
        SharedCaptureInbox.shared.enqueue(.asset(
            id: UUID().uuidString.lowercased(),
            asset: asset
        ))
        drainSharedCapturesIfReady()
    }

    public func processSharedCaptures() {
        drainSharedCapturesIfReady()
    }

    private func drainSharedCapturesIfReady() {
        guard didApplyLocalLaunchResult, sharedCaptureTask == nil else { return }
        sharedCaptureTask = Task { [weak self] in
            guard let self else { return }
            await SharedCaptureProcessor.process(inbox: SharedCaptureInbox.shared) { item in
                switch item.kind {
                case .text:
                    guard let text = item.captureText else { return true }
                    return await self.store.captureSharedText(text, id: item.id)
                case .asset:
                    guard let asset = item.captureAsset else { return true }
                    #if !SKIP
                    guard let imported = try? SharedCaptureAssetImporter.importAsset(
                        asset,
                        sharedDirectory: SharedCaptureStorage.sharedDirectory,
                        documentsDirectory: .documentsDirectory
                    ) else { return false }
                    return await self.store.captureSharedAsset(
                        id: item.id,
                        title: imported.title,
                        assetType: imported.assetType,
                        assetSize: imported.size,
                        assetChecksum: imported.checksum,
                        localPath: imported.localPath
                    )
                    #else
                    return await self.store.captureSharedAsset(
                        id: item.id,
                        title: asset.title,
                        assetType: asset.assetType,
                        assetSize: asset.size,
                        assetChecksum: asset.checksum,
                        localPath: asset.stagedFileName
                    )
                    #endif
                }
            }
            self.sharedCaptureTask = nil
        }
    }

    public func openStore() {
        store.open(path: databasePath)
    }

    public func syncFromStoredConnection() async -> Bool {
        await waitForLocalLaunchLoad()
        let defaults = UserDefaults.standard
        let baseURL = defaults.string(forKey: "logseq.baseURL") ?? "http://127.0.0.1:8787"
        guard let graphID = defaults.string(forKey: "logseq.selectedGraphId"), !graphID.isEmpty else {
            return false
        }
        guard let token = try? await authentication.accessToken() else { return false }
        await store.configureAndSelectGraph(
            baseURL: baseURL,
            token: token,
            selectedGraphID: graphID,
            refreshGraphCatalog: false
        )
        guard store.lastError == nil else { return false }
        let isEncrypted = store.snapshot.graphs?.first(where: { $0.id == graphID })?.isEncrypted ?? false
        if isEncrypted && store.snapshot.isGraphUnlocked != true { return false }
        guard await store.bootstrapSelectedGraph(
            graphID: graphID,
            baseURL: baseURL,
            accessToken: token,
            allowSnapshotDownload: false,
            isEncrypted: isEncrypted
        ) else { return false }
        await store.syncPendingForBackground()
        guard store.lastError == nil else { return false }
        _ = await store.runGraphEventsOnce(
            graphID: graphID,
            baseURL: baseURL,
            accessToken: token,
            stopAfterFirstFrame: true
        )
        return store.lastError == nil
    }

    public func runExclusiveBackgroundSync() async -> Bool {
        await syncCoordinator.runBackground {
            await LogseqChatRuntime.shared.syncFromStoredConnection()
        }
    }

    public func cancelBackgroundSync() async {
        await syncCoordinator.cancelBackground()
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

    @MainActor public static func syncNow() {
        #if os(iOS) && !SKIP
        BackgroundSyncExecution().start()
        #endif
    }

    @MainActor private static func runOnce() async -> Bool {
        await LogseqChatRuntime.shared.runExclusiveBackgroundSync()
    }

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
        let completion = BackgroundTaskCompletion()
        let refreshTask = Task {
            let success = await runOnce()
            await completion.finish(success: success) { result in
                task.setTaskCompleted(success: result)
            }
        }
        task.expirationHandler = {
            Task { @MainActor in
                refreshTask.cancel()
                await LogseqChatRuntime.shared.cancelBackgroundSync()
                completion.finish(success: false) { result in
                    task.setTaskCompleted(success: result)
                }
            }
        }
    }
    #endif
}

#if os(iOS) && !SKIP
@MainActor private final class BackgroundSyncExecution {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var syncTask: Task<Void, Never>?

    func start() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Logseq graph sync") { [weak self] in
            self?.expire()
        }
        syncTask = Task { [self] in
            _ = await LogseqChatRuntime.shared.runExclusiveBackgroundSync()
            finish()
        }
    }

    private func expire() {
        syncTask?.cancel()
        Task { [self] in
            await LogseqChatRuntime.shared.cancelBackgroundSync()
            finish()
        }
    }

    private func finish() {
        syncTask = nil
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif

/// Global application delegate functions.
///
/// These functions can update a shared observable object to communicate app state changes to interested views.
public final class LogseqChatAppDelegate : Sendable {
    public static let shared = LogseqChatAppDelegate()

    private init() {
    }

    private nonisolated(unsafe) var launchStartedAt: TimeInterval?

    @MainActor public func onInit() {
        let now = Date().timeIntervalSince1970
        launchStartedAt = now
        print(String(format: "LOGSEQ_LAUNCH_METRIC start=%.6f", now))
        LogseqChatRuntime.shared.startLocalLaunchLoad()
        logger.debug("onInit")
    }

    public func onLaunch() {
        reportLaunchMetric("did_finish_launching")
        logger.debug("onLaunch")
    }

    public func onFirstUIRendered() {
        reportLaunchMetric("first_ui_rendered")
    }

    public func onJournalsUIReady() {
        reportLaunchMetric("journals_ui_ready")
    }

    public func launchElapsedMilliseconds() -> Double? {
        guard let launchStartedAt else { return nil }
        return (Date().timeIntervalSince1970 - launchStartedAt) * 1_000.0
    }

    public func reportLaunchStage(_ name: String) {
        reportLaunchMetric(name)
    }

    private func reportLaunchMetric(_ name: String) {
        guard let elapsedMilliseconds = launchElapsedMilliseconds() else { return }
        print(String(format: "LOGSEQ_LAUNCH_METRIC %@_ms=%.3f", name, elapsedMilliseconds))
    }

    @MainActor public func onResume() {
        LogseqChatRuntime.shared.processSharedCaptures()
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
