import Foundation
import LogseqChatModel

struct LGChatGraphSnapshotEnvelope: Codable {
    let apiVersion: Int
    let ok: Bool
    let result: LogseqChatSnapshot
}

enum LGChatGraphEffectResolution {
    static func make(
        succeeded: Bool,
        snapshot: LogseqChatSnapshot,
        errorMessage: String?
    ) -> LGChatEffectResolution {
        guard succeeded else {
            return LGChatEffectResolution(
                succeeded: false,
                message: errorMessage ?? "The graph operation failed",
                output: .discard
            )
        }
        do {
            let data = try JSONEncoder().encode(LGChatGraphSnapshotEnvelope(
                apiVersion: 1,
                ok: true,
                result: snapshot
            ))
            guard let message = String(data: data, encoding: .utf8) else {
                throw LGChatGraphSnapshotEncodingError.invalidUTF8
            }
            return LGChatEffectResolution(
                succeeded: true,
                message: message,
                output: .coreResponse
            )
        } catch {
            return LGChatEffectResolution(
                succeeded: false,
                message: "Could not encode the graph snapshot: \(error)",
                output: .discard
            )
        }
    }
}

private enum LGChatGraphSnapshotEncodingError: Error {
    case invalidUTF8
}

@MainActor
final class LGChatGraphLifecycle {
    var localGraphIDsChanged: (([String]) -> Void)?

    private let store: LogseqChatStore
    private let authentication: LogseqAuthenticationStore
    private let syncCoordinator: GraphSyncCoordinator
    private let databasePath: String
    private let openCreatedGraph: (@MainActor (String) async -> LGChatEffectResolution)?

    init(
        store: LogseqChatStore,
        authentication: LogseqAuthenticationStore,
        syncCoordinator: GraphSyncCoordinator,
        databasePath: String,
        openCreatedGraph: (@MainActor (String) async -> LGChatEffectResolution)? = nil
    ) {
        self.store = store
        self.authentication = authentication
        self.syncCoordinator = syncCoordinator
        self.databasePath = databasePath
        self.openCreatedGraph = openCreatedGraph
    }

    func execute(_ effect: LGChatEffect) async -> LGChatEffectResolution {
        switch effect.kind {
        case "open-graph":
            return await openGraph(effect.text)
        case "unlock-graph":
            return await unlockGraph(effect.text)
        case "create-graph":
            guard await store.createSyncGraph(
                name: effect.text,
                isEncrypted: effect.value == 1
            ), let graphID = store.snapshot.selectedGraphId, !graphID.isEmpty else {
                return resolution(succeeded: false)
            }
            let openResolution = if let openCreatedGraph {
                await openCreatedGraph(graphID)
            } else {
                await openGraph(graphID, persistSelection: false)
            }
            guard openResolution.succeeded else { return openResolution }
            UserDefaults.standard.set(graphID, forKey: "logseq.selectedGraphId")
            return openResolution
        case "delete-local-graph":
            return await deleteLocalGraph(effect.text)
        default:
            return LGChatEffectResolution(
                succeeded: false,
                message: "Unsupported graph platform effect: \(effect.kind)",
                output: .discard
            )
        }
    }

    func connectStoredGraph() async -> Bool {
        let defaults = UserDefaults.standard
        let baseURL = defaults.string(forKey: "logseq.baseURL")
            ?? "http://127.0.0.1:8787"
        let storedGraphID = defaults.string(forKey: "logseq.selectedGraphId") ?? ""
        let graphID = storedGraphID.isEmpty ? nil : storedGraphID
        guard let accessToken = try? await authentication.accessToken() else {
            return false
        }
        await store.configureAndSelectGraph(
            baseURL: baseURL,
            token: accessToken,
            selectedGraphID: graphID
        )
        guard store.lastError == nil else { return false }
        guard let graphID else { return true }

        let isEncrypted = store.snapshot.graphs?
            .first(where: { $0.id == graphID })?.isEncrypted ?? false
        if isEncrypted && store.snapshot.isGraphUnlocked != true {
            return true
        }
        guard await store.bootstrapSelectedGraph(
            graphID: graphID,
            baseURL: baseURL,
            accessToken: accessToken,
            isEncrypted: isEncrypted
        ) else { return false }
        startSync(graphID: graphID, baseURL: baseURL, isEncrypted: isEncrypted)
        return true
    }

    private func openGraph(
        _ graphID: String,
        persistSelection: Bool = true
    ) async -> LGChatEffectResolution {
        guard await store.selectGraphAndWait(graphID) else {
            return resolution(succeeded: false)
        }

        let baseURL = UserDefaults.standard.string(forKey: "logseq.baseURL")
            ?? "http://127.0.0.1:8787"
        let accessToken = (try? await authentication.accessToken()) ?? ""
        let isEncrypted = store.snapshot.graphs?
            .first(where: { $0.id == graphID })?.isEncrypted ?? false
        let opened = await store.bootstrapSelectedGraph(
            graphID: graphID,
            baseURL: baseURL,
            accessToken: accessToken,
            allowSnapshotDownload: !accessToken.isEmpty,
            isEncrypted: isEncrypted
        )
        guard opened else { return resolution(succeeded: false) }

        if persistSelection {
            UserDefaults.standard.set(graphID, forKey: "logseq.selectedGraphId")
        }
        publishLocalGraphIDs()
        if !accessToken.isEmpty,
           !isEncrypted || store.snapshot.isGraphUnlocked == true {
            startSync(graphID: graphID, baseURL: baseURL, isEncrypted: isEncrypted)
        }
        return resolution(succeeded: true)
    }

    private func unlockGraph(_ password: String) async -> LGChatEffectResolution {
        await store.unlockGraph(password)
        guard store.lastError == nil, store.snapshot.isGraphUnlocked == true else {
            return LGChatEffectResolution(
                succeeded: false,
                message: store.lastError?.message ?? "The graph is still locked",
                output: .discard
            )
        }

        guard let graphID = store.snapshot.selectedGraphId,
              !graphID.isEmpty
        else {
            return LGChatEffectResolution(
                succeeded: false,
                message: "The unlocked graph has no selected identifier",
                output: .discard
            )
        }
        let baseURL = UserDefaults.standard.string(forKey: "logseq.baseURL")
            ?? "http://127.0.0.1:8787"
        let accessToken = (try? await authentication.accessToken()) ?? ""
        if !accessToken.isEmpty {
            startSync(graphID: graphID, baseURL: baseURL, isEncrypted: true)
        }
        return resolution(succeeded: true)
    }

    private func deleteLocalGraph(_ graphID: String) async -> LGChatEffectResolution {
        let defaults = UserDefaults.standard
        let deletingSelected = defaults.string(forKey: "logseq.selectedGraphId") == graphID
            || store.snapshot.selectedGraphId == graphID
        if deletingSelected {
            await syncCoordinator.stopForeground()
            await store.resetToCatalog()
        }
        do {
            try LogseqGraphLocalStorage.delete(databasePath: databasePath, graphID: graphID)
        } catch {
            return LGChatEffectResolution(
                succeeded: false,
                message: error.localizedDescription,
                output: .discard
            )
        }
        if deletingSelected {
            defaults.set("", forKey: "logseq.selectedGraphId")
            let accessToken = (try? await authentication.accessToken()) ?? ""
            await store.configureAndSelectGraph(
                baseURL: defaults.string(forKey: "logseq.baseURL")
                    ?? "http://127.0.0.1:8787",
                token: accessToken,
                selectedGraphID: nil
            )
        }
        publishLocalGraphIDs()
        return resolution(succeeded: true)
    }

    private func publishLocalGraphIDs() {
        let graphIDs = (store.snapshot.graphs ?? []).compactMap { graph in
            LogseqGraphLocalStorage.isDownloaded(
                databasePath: databasePath,
                graphID: graph.id
            ) ? graph.id : nil
        }
        localGraphIDsChanged?(graphIDs)
    }

    private func resolution(succeeded: Bool) -> LGChatEffectResolution {
        LGChatGraphEffectResolution.make(
            succeeded: succeeded,
            snapshot: store.snapshot,
            errorMessage: store.lastError?.message
        )
    }

    private func startSync(graphID: String, baseURL: String, isEncrypted: Bool) {
        Task {
            await syncCoordinator.startForeground(graphID: graphID) { [weak self] graphID in
                guard let self else { return }
                var reconnectAttempt = 0
                while !Task.isCancelled && authentication.state == .signedIn {
                    guard let accessToken = try? await authentication.accessToken() else { return }
                    let cursorBeforeConnection = store.snapshot.appliedServerT
                    let snapshotRequired = await store.runGraphEventsOnce(
                        graphID: graphID,
                        baseURL: baseURL,
                        accessToken: accessToken
                    )
                    if store.snapshot.appliedServerT != cursorBeforeConnection {
                        reconnectAttempt = 0
                    }
                    if LogseqGraphWebSocketReconnectPolicy.shouldReconnect(store.syncError) {
                        let delay = LogseqGraphWebSocketReconnectPolicy.delaySeconds(
                            attempt: reconnectAttempt
                        )
                        reconnectAttempt += 1
                        if !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(delay))
                        }
                        continue
                    }
                    guard store.syncError == nil else { return }
                    let shouldRefresh = LogseqGraphSnapshotRefreshPolicy.shouldRefresh(
                        snapshotRequired: snapshotRequired,
                        isEditingOutlinerBlock: store.snapshot.outlinerState.editing != nil
                    )
                    if snapshotRequired && !shouldRefresh {
                        store.deferSnapshotRefreshWhileEditing()
                    } else if shouldRefresh {
                        guard let refreshedToken = try? await authentication.accessToken(),
                              await store.bootstrapSelectedGraph(
                                graphID: graphID,
                                baseURL: baseURL,
                                accessToken: refreshedToken,
                                forceSnapshot: true,
                                isEncrypted: isEncrypted
                              )
                        else { return }
                    }
                    if !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            }
        }
    }
}
