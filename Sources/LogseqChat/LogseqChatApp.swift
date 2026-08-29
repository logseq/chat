import Foundation
import OSLog
import SwiftUI
import LogseqChatModel
import LUIAppleBackend

#if os(iOS) && !SKIP
@preconcurrency import BackgroundTasks
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct LogseqAppLogger {
    #if !SKIP
    private let systemLogger = os.Logger(subsystem: "com.logseq.chat", category: "LogseqChat")
    #endif

    func debug(_ message: String) {
        LogseqRuntimeLog.shared.append(level: .debug, source: .ui, message: message)
        #if SKIP
        print(message)
        #else
        systemLogger.debug("\(message, privacy: .public)")
        #endif
    }

    func info(_ message: String) {
        LogseqRuntimeLog.shared.append(level: .info, source: .ui, message: message)
        #if SKIP
        print(message)
        #else
        systemLogger.info("\(message, privacy: .public)")
        #endif
    }

    func error(_ message: String) {
        LogseqRuntimeLog.shared.append(level: .error, source: .ui, message: message)
        #if SKIP
        print(message)
        #else
        systemLogger.error("\(message, privacy: .public)")
        #endif
    }
}

let logger = LogseqAppLogger()

@MainActor
private final class LGChatCoreResponseRelay {
    var apply: ((String) -> Void)?

    func send(_ response: String) {
        if let apply {
            apply(response)
        }
    }
}

/// The shared top-level view for the app, loaded from the platform-specific App delegates below.
public struct LogseqChatRootView : View {
    @AppStorage("logseq.appearance") private var appearance = "system"
    @AppStorage("logseq.language") private var language = "system"
    @Environment(\.colorScheme) private var colorScheme

    private let runtime = LogseqChatRuntime.shared

    public init() {
    }

    public var body: some View {
        appContent
        .preferredColorScheme(
            appearance == "light" ? .light : (appearance == "dark" ? .dark : nil)
        )
        .environment(\.locale, preferredLocale)
        .tint(LogseqThemePolicy.accent)
        .luiSemanticColors([
            "background": themePalette.background,
            "surface": themePalette.surface,
            "muted-foreground": themePalette.secondaryText,
            "task-backlog": Color(red: 0.66, green: 0.64, blue: 0.62),
            "task-todo": Color(red: 0.47, green: 0.44, blue: 0.42),
            "task-doing": Color(red: 0.79, green: 0.54, blue: 0.02),
            "task-in-review": Color(red: 0.11, green: 0.31, blue: 0.85),
            "task-done": Color(red: 0.09, green: 0.64, blue: 0.29),
            "task-canceled": Color(red: 0.86, green: 0.15, blue: 0.15),
        ])
        .background(themePalette.background.ignoresSafeArea())
    }

    private var appContent: some View {
        LGChatRendererRoot(renderer: runtime.lgRuntime.renderer)
            .onAppear {
                DispatchQueue.main.async {
                    LogseqChatAppDelegate.shared.onFirstUIRendered()
                }
            }
            .task {
                await runtime.runLGApplication()
                logger.info("Skip app logs are viewable in the Xcode console for iOS; Android logs can be viewed in Studio or using adb logcat")
            }
            #if !SKIP
            .task {
                for await available in NetworkAvailabilityStream.values() {
                    await runtime.setNetworkAvailable(available)
                }
            }
            #endif
            .onChange(of: runtime.authentication.state) { _, state in
                runtime.publishAuthenticationState()
                guard state == .signedIn else { return }
                Task { await runtime.resumeLGApplication() }
            }
            .onOpenURL { url in
                runtime.acceptSharedCaptureURL(url)
            }
            #if !SKIP
            .modifier(LGChatPlatformPresentationHost(
                coordinator: runtime.presentationCoordinator,
                store: runtime.store
            ))
            #endif
    }

    private var preferredLocale: Locale {
        let identifier = LogseqSettingsPolicy.normalizedLanguageID(language)
        return identifier == "system" ? Locale.current : Locale(identifier: identifier)
    }

    private var themePalette: LogseqThemePalette {
        LogseqThemePolicy.palette(
            mode: LogseqThemeMode(rawValue: appearance) ?? .system,
            systemIsDark: colorScheme == .dark
        )
    }

}

@MainActor public final class LogseqChatRuntime {
    public static let shared = LogseqChatRuntime()

    public let store: LogseqChatStore
    public let lgRuntime: LGChatRuntime
    public let authentication: LogseqAuthenticationStore
    public let presentationCoordinator: LGChatPlatformPresentationCoordinator
    let syncCoordinator: GraphSyncCoordinator
    private struct LocalLaunchResult: Sendable {
        let catalogResponse: String
        let graphResponse: String?
        let isEncrypted: Bool?
    }
    private var localLaunchTask: Task<LocalLaunchResult, Never>?
    private var didApplyLocalLaunchResult = false
    private var sharedCaptureTask: Task<Void, Never>?
    private var didStartLGApplication = false
    private var isLGApplicationReady = false
    private let graphLifecycle: LGChatGraphLifecycle
    private let platformCommandRouter: LGChatPlatformCommandRouter

    private struct SettingsHostPayload: Encodable {
        let appearance: String
        let language: String
        let spellCheck: Bool
        let autoCorrection: Bool
        let sidebarTabs: [String]
        let baseURL: String
        let version: String
        let revision: String
    }

    private struct AuthenticationHostPayload: Encodable {
        let state: String
        let errorMessage: String?
    }

    private init() {
        try? FileManager.default.removeItem(
            at: URL.documentsDirectory.appendingPathComponent("cached-home-snapshot.json")
        )
        let responseRelay = LGChatCoreResponseRelay()
        let store = LogseqChatStore(
            call: { request in LogseqChatCore.shared.logseq_chat_call(request) },
            responseObserver: responseRelay.send
        )
        let configuration = LogseqCognitoConfiguration.load()
        let authentication = LogseqAuthenticationStore(
            provider: CognitoAuthProvider(
                region: configuration.region,
                userPoolId: configuration.userPoolId,
                appClientId: configuration.appClientId,
                oauthDomain: configuration.oauthDomain,
                redirectURI: configuration.redirectURI,
                logoutURI: configuration.logoutURI,
                scopes: configuration.scopes
            )
        )
        let syncCoordinator = GraphSyncCoordinator()
        let presentationCoordinator = LGChatPlatformPresentationCoordinator()
        let databasePath = URL.documentsDirectory
            .appendingPathComponent("logseq-chat.sqlite")
            .path
        let graphLifecycle = LGChatGraphLifecycle(
            store: store,
            authentication: authentication,
            syncCoordinator: syncCoordinator,
            databasePath: databasePath
        )
        let platformHandler = LGChatPlatformEffectHandler(
            saveSettings: { settings in
                let defaults = UserDefaults.standard
                defaults.set(settings.appearance, forKey: "logseq.appearance")
                defaults.set(
                    LogseqSettingsPolicy.normalizedLanguageID(settings.language),
                    forKey: "logseq.language"
                )
                defaults.set(settings.spellCheck, forKey: "logseq.editor.spellCheck")
                defaults.set(
                    settings.autoCorrection,
                    forKey: "logseq.editor.autoCorrection"
                )
                defaults.set(
                    settings.sidebarTabs.joined(separator: ","),
                    forKey: "logseq.mobile.sidebarTabs"
                )
                defaults.set(settings.baseURL, forKey: "logseq.baseURL")
            },
            persistComposerDraft: { draft in
                UserDefaults.standard.set(draft, forKey: "logseq.composerDraft")
            },
            runtimeLog: .shared,
            copyText: { text in Self.copyText(text) },
            signIn: {
                await authentication.signIn()
                let message = authentication.state == .signedIn
                    ? nil
                    : authentication.errorMessage ?? "Hosted sign-in failed"
                return message
            },
            signOut: {
                await syncCoordinator.stopForeground()
                await authentication.signOut()
                let defaults = UserDefaults.standard
                defaults.set("", forKey: "logseq.selectedGraphId")
                store.configure(
                    baseURL: defaults.string(forKey: "logseq.baseURL")
                        ?? "http://127.0.0.1:8787",
                    token: "",
                    refreshAfterApply: false
                )
            },
            openExternalURL: { url in
                #if SKIP
                return AndroidAssetImporter.openURL(url.absoluteString)
                #elseif os(iOS)
                return await UIApplication.shared.open(url)
                #elseif os(macOS)
                return NSWorkspace.shared.open(url)
                #else
                return false
                #endif
            },
            exportGraphDatabase: {
                guard let graphID = store.snapshot.selectedGraphId,
                      !graphID.isEmpty
                else { return false }
                let databaseURL = LogseqGraphLocalStorage.directoryURL(
                    databasePath: databasePath,
                    graphID: graphID
                ).appendingPathComponent("graph.sqlite")
                #if SKIP
                AndroidAssetImporter.share(text: "", paths: [databaseURL.path])
                return true
                #elseif os(iOS)
                return presentationCoordinator.presentFile(databaseURL)
                #else
                return false
                #endif
            },
            graphEffect: { effect in await graphLifecycle.execute(effect) },
            presentAttachment: { kind in
                presentationCoordinator.presentAttachment(kind)
            },
            presentAsset: { asset in
                #if SKIP
                guard !asset.localPath.isEmpty else { return false }
                AndroidAssetImporter.openFile(
                    path: asset.localPath,
                    contentType: asset.assetType.isEmpty
                        ? "application/octet-stream"
                        : asset.assetType
                )
                return true
                #elseif os(iOS)
                return presentationCoordinator.presentAsset(asset)
                #else
                return false
                #endif
            },
            presentPageShare: { payload in
                #if SKIP
                AndroidAssetImporter.share(
                    text: payload.text,
                    paths: payload.localAssetPaths
                )
                return true
                #elseif os(iOS)
                return presentationCoordinator.presentPageShare(payload)
                #else
                Self.copyText(payload.text)
                return true
                #endif
            },
            syncNow: { store.syncPending() }
        )
        let platformCommandRouter = LGChatPlatformCommandRouter(
            setClipboardText: { text in Self.copyText(text) },
            performHaptic: { style in Self.performHaptic(style) },
            present: { presentation in
                switch presentation {
                case .confirmDelete(let blockIDs):
                    presentationCoordinator.confirmDeletion(of: blockIDs)
                case .pickAttachment(let blockID):
                    _ = presentationCoordinator.presentAttachment(
                        "files",
                        targetBlockID: blockID
                    )
                case .takePhoto(let blockID):
                    _ = presentationCoordinator.presentAttachment(
                        "camera",
                        targetBlockID: blockID
                    )
                case .recordAudio(let blockID):
                    _ = presentationCoordinator.presentAttachment(
                        "audio",
                        targetBlockID: blockID
                    )
                case .focusBlock:
                    break
                }
            }
        )
        let effectExecutor = LGChatCoreEffectExecutor(
            platformEffect: { effect in await platformHandler.execute(effect) }
        )
        self.store = store
        self.authentication = authentication
        self.presentationCoordinator = presentationCoordinator
        self.syncCoordinator = syncCoordinator
        self.graphLifecycle = graphLifecycle
        self.platformCommandRouter = platformCommandRouter
        let lgRuntime = LGChatRuntime(
            native: LGChatCoreNativeCaller(),
            effectExecutor: effectExecutor,
            platformCommandHandler: platformCommandRouter
        )
        self.lgRuntime = lgRuntime
        responseRelay.apply = { [weak lgRuntime] response in
            do {
                try lgRuntime?.applyCoreResponse(response)
            } catch {
                logger.error(
                    "Could not relay a platform core response into LG: "
                        + String(describing: error)
                )
            }
        }
        graphLifecycle.localGraphIDsChanged = { [weak lgRuntime] graphIDs in
            guard let data = try? JSONEncoder().encode(graphIDs),
                  let payload = String(data: data, encoding: .utf8)
            else { return }
            do {
                try lgRuntime?.applyHostUpdate(kind: "local-graph-ids", payload: payload)
            } catch {
                logger.error(
                    "Could not relay local graph identifiers into LG: "
                        + String(describing: error)
                )
            }
        }
    }

    public var databasePath: String {
        URL.documentsDirectory
            .appendingPathComponent("logseq-chat.sqlite")
            .path
    }

    public func startLGRenderer() {
        do {
            try lgRuntime.start(platformCode: Self.lgPlatformCode)
            try lgRuntime.applyHostUpdate(
                kind: "graph-loading",
                payload: !didApplyLocalLaunchResult ? "true" : "false"
            )
            try lgRuntime.applyHostUpdate(
                kind: "settings",
                payload: try Self.settingsHostPayload()
            )
            try lgRuntime.applyHostUpdate(
                kind: "authentication",
                payload: try authenticationHostPayload()
            )
            let persistedDraft = UserDefaults.standard.string(
                forKey: "logseq.composerDraft"
            ) ?? ""
            let persistedDraftData = try JSONEncoder().encode(persistedDraft)
            try lgRuntime.applyHostUpdate(
                kind: "composer-draft",
                payload: String(data: persistedDraftData, encoding: .utf8) ?? "\"\""
            )
        } catch {
            logger.error("Could not start LG renderer: \(String(describing: error))")
        }
    }

    public func runLGApplication() async {
        guard !didStartLGApplication else { return }
        didStartLGApplication = true
        startLGRenderer()
        await waitForLocalLaunchLoad()
        await authentication.restore()
        publishAuthenticationState()
        isLGApplicationReady = true
        await resumeLGApplication()
        await store.runPendingSyncLoop()
    }

    public func resumeLGApplication() async {
        guard isLGApplicationReady else { return }
        processSharedCaptures()
        guard authentication.state == .signedIn else { return }
        let connected = await graphLifecycle.connectStoredGraph()
        do {
            try lgRuntime.applyHostUpdate(kind: "graph-loading", payload: "false")
        } catch {
            logger.error(
                "Could not finish LG graph catalog loading: "
                    + String(describing: error)
            )
        }
        if !connected {
            logger.error("Could not restore the stored graph connection")
        }
    }

    public func setNetworkAvailable(_ available: Bool) async {
        await syncCoordinator.setNetworkAvailable(available)
    }

    public func publishAuthenticationState() {
        do {
            try lgRuntime.applyHostUpdate(
                kind: "authentication",
                payload: try authenticationHostPayload()
            )
        } catch {
            logger.error(
                "Could not publish authentication state to LG: "
                    + String(describing: error)
            )
        }
    }

    private func authenticationHostPayload() throws -> String {
        let payload = AuthenticationHostPayload(
            state: authentication.state.rawValue,
            errorMessage: authentication.errorMessage
        )
        return String(data: try JSONEncoder().encode(payload), encoding: .utf8) ?? "{}"
    }

    private static func settingsHostPayload() throws -> String {
        let defaults = UserDefaults.standard
        let rawTabs = defaults.string(forKey: "logseq.mobile.sidebarTabs") ?? ""
        let payload = SettingsHostPayload(
            appearance: defaults.string(forKey: "logseq.appearance") ?? "system",
            language: LogseqSettingsPolicy.normalizedLanguageID(
                defaults.string(forKey: "logseq.language") ?? "system"
            ),
            spellCheck: defaults.object(forKey: "logseq.editor.spellCheck") as? Bool ?? true,
            autoCorrection: defaults.object(forKey: "logseq.editor.autoCorrection") as? Bool
                ?? true,
            sidebarTabs: rawTabs.isEmpty
                ? []
                : rawTabs.split(separator: ",").map { value in String(value) },
            baseURL: defaults.string(forKey: "logseq.baseURL")
                ?? "http://127.0.0.1:8787",
            version: LogseqSettingsPolicy.version,
            revision: LogseqSettingsPolicy.revision
        )
        return String(data: try JSONEncoder().encode(payload), encoding: .utf8) ?? "{}"
    }

    private static func copyText(_ text: String) {
        #if SKIP
        AndroidAssetImporter.copyText(text: text)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    private static func performHaptic(_ style: String?) {
        #if !SKIP && os(iOS)
        if style == "selection" {
            UISelectionFeedbackGenerator().selectionChanged()
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        #endif
    }

    private static var lgPlatformCode: Int {
        #if SKIP
        3
        #elseif os(macOS)
        1
        #else
        2
        #endif
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
        applyLocalGraphIDsToLG(from: result.catalogResponse)
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
        if lgRuntime.isStarted, result.graphResponse != nil {
            do {
                try lgRuntime.applyHostUpdate(kind: "graph-loading", payload: "false")
            } catch {
                logger.error(
                    "Could not finish LG graph loading: " + String(describing: error)
                )
            }
        }
        if result.graphResponse != nil {
            LogseqChatAppDelegate.shared.onJournalsUIReady()
        }
        drainSharedCapturesIfReady()
    }

    private func applyLocalGraphIDsToLG(from catalogResponse: String) {
        guard let data = catalogResponse.data(using: .utf8),
              let response = try? JSONDecoder().decode(LogseqChatRPCResponse.self, from: data)
        else { return }
        let graphIDs = (response.result?.graphs ?? []).compactMap { graph in
            LogseqGraphLocalStorage.isDownloaded(
                databasePath: databasePath,
                graphID: graph.id
            ) ? graph.id : nil
        }
        guard let payloadData = try? JSONEncoder().encode(graphIDs),
              let payload = String(data: payloadData, encoding: .utf8)
        else { return }
        do {
            try lgRuntime.applyHostUpdate(kind: "local-graph-ids", payload: payload)
        } catch {
            logger.error("Could not project local graphs into LG: \(String(describing: error))")
        }
    }

    public func acceptSharedCaptureURL(_ url: URL) {
        guard let deepLink = LogseqDeepLink(url) else { return }
        switch deepLink {
        case .captureText(let text):
            SharedCaptureInbox.shared.enqueueText(text)
            drainSharedCapturesIfReady()
        case .openCapture:
            do {
                try lgRuntime.applyHostUpdate(kind: "open-capture", payload: "{}")
            } catch {
                logger.error("Could not present LG capture: \(String(describing: error))")
            }
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
    let oauthDomain: String
    let redirectURI: String
    let logoutURI: String
    let scopes: [String]

    static func load() -> LogseqCognitoConfiguration {
        guard
            let url = Bundle.module.url(forResource: "logseq-auth", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let configuration = try? JSONDecoder().decode(LogseqCognitoConfiguration.self, from: data)
        else {
            return LogseqCognitoConfiguration(
                region: "",
                userPoolId: "",
                appClientId: "",
                oauthDomain: "",
                redirectURI: "",
                logoutURI: "",
                scopes: []
            )
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
            logger.error("Could not schedule background refresh: \(String(describing: error))")
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
        Task { await LogseqChatRuntime.shared.resumeLGApplication() }
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
