import Foundation
import LogseqChatModel

@MainActor
final class LGChatGraphLifecycle {
    var localGraphIDsChanged: (([String]) -> Void)?

    private let store: LogseqChatStore
    private let authentication: LogseqAuthenticationStore
    private let syncCoordinator: GraphSyncCoordinator
    private let databasePath: String

    init(
        store: LogseqChatStore,
        authentication: LogseqAuthenticationStore,
        syncCoordinator: GraphSyncCoordinator,
        databasePath: String
    ) {
        self.store = store
        self.authentication = authentication
        self.syncCoordinator = syncCoordinator
        self.databasePath = databasePath
    }

    func execute(_ effect: LGChatEffect) async -> LGChatEffectResolution {
        switch effect.kind {
        case "open-graph":
            return await openGraph(effect.text)
        case "unlock-graph":
            return await unlockGraph(effect.text)
        case "create-graph":
            let succeeded = await store.createSyncGraph(
                name: effect.text,
                isEncrypted: effect.value == 1
            )
            return resolution(succeeded: succeeded)
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

    private func openGraph(_ graphID: String) async -> LGChatEffectResolution {
        UserDefaults.standard.set(graphID, forKey: "logseq.selectedGraphId")
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
        LGChatEffectResolution(
            succeeded: succeeded,
            message: succeeded
                ? ""
                : store.lastError?.message ?? "The graph operation failed",
            output: .discard
        )
    }

    private func startSync(graphID: String, baseURL: String, isEncrypted: Bool) {
        Task {
            await syncCoordinator.startForeground(graphID: graphID) { [weak self] graphID in
                guard let self else { return }
                while !Task.isCancelled && authentication.state == .signedIn {
                    guard let accessToken = try? await authentication.accessToken() else { return }
                    let snapshotRequired = await store.runGraphEventsOnce(
                        graphID: graphID,
                        baseURL: baseURL,
                        accessToken: accessToken
                    )
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
