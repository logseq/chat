import SwiftUI
import LogseqChatModel
import Observation
#if !SKIP
import CryptoKit
import PhotosUI
import UniformTypeIdentifiers
#if os(iOS)
import AVKit
import QuickLook
import UIKit
#elseif os(macOS)
import AppKit
#endif
#endif
#if SKIP
import androidx.activity.compose.BackHandler
#endif

private enum SidebarChromeMetrics {
    static let iOSHeaderTopPadding: CGFloat = 64
    static let androidHeaderTopPadding: CGFloat = 12
    static let menuGlyphWidth: CGFloat = 18
    static let menuVisualFrame: CGFloat = 24
    static let minimumHitTarget: CGFloat = 44
    static let headerBottomPadding: CGFloat = 8
    static let headerHeight = minimumHitTarget + headerBottomPadding
}

private struct SidebarMenuIcon: View {
    var body: some View {
        IconImage(
            name: SidebarMenuIconPolicy.assetName,
            size: SidebarMenuIconPolicy.assetSize
        )
        .frame(
            width: SidebarChromeMetrics.menuVisualFrame,
            height: SidebarChromeMetrics.menuVisualFrame
        )
        .foregroundStyle(.primary)
    }
}

@MainActor @Observable final class SidebarMotionState {
    var isPresented = false
    var isAnimating = false
    var dragOffset: CGFloat = 0.0

    func setSidebarPresented(_ presented: Bool) {
        guard presented != isPresented || abs(dragOffset) > 0.0 else { return }
        isAnimating = true
        #if SKIP
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            isPresented = presented
            dragOffset = 0.0
        }
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            isAnimating = false
        }
        #else
        withAnimation(
            .spring(response: 0.28, dampingFraction: 0.9),
            completionCriteria: .logicallyComplete
        ) {
            isPresented = presented
            dragOffset = 0
        } completion: {
            self.isAnimating = false
        }
        #endif
    }
}

private struct SidebarMotionShell<Sidebar: View, Main: View>: View {
    let motion: SidebarMotionState
    let activationAvailable: Bool
    let sidebar: Sidebar
    let main: Main

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width * 0.84, 360.0)
            let baseOffset = motion.isPresented ? width : 0.0
            let contentOffset = min(max(baseOffset + motion.dragOffset, 0.0), width)
            let progress = width > 0.0 ? contentOffset / width : 0.0
            let isDragging = abs(motion.dragOffset) > 0.0

            ZStack(alignment: .leading) {
                #if SKIP
                ComposeView { _ in
                    BackHandler(enabled: motion.isPresented) {
                        motion.setSidebarPresented(false)
                    }
                }
                .frame(width: 0, height: 0)
                #endif

                sidebar
                    .frame(width: width)
                    .scrollDisabled(SidebarDragPolicy.disablesScrollEnvironment(
                        isDragging: isDragging,
                        isAnimating: motion.isAnimating
                    ))
                    .allowsHitTesting(SidebarDragPolicy.allowsSidebarInteraction(
                        isPresented: motion.isPresented,
                        isDragging: isDragging,
                        isAnimating: motion.isAnimating
                    ))
                    .background(Color.black.opacity(0.001))
                    .opacity(0.35 + (0.65 * progress))
                    .scaleEffect(0.96 + (0.04 * progress))
                    .offset(x: -20.0 * (1.0 - progress))

                main
                    .platformSidebarSafeAreaPadding(
                        top: geometry.safeAreaInsets.top,
                        bottom: MobileChromePolicy.mainPanelBottomSafeAreaPadding
                    )
                    .scrollDisabled(SidebarDragPolicy.disablesScrollEnvironment(
                        isDragging: isDragging,
                        isAnimating: motion.isAnimating
                    ))
                    .allowsHitTesting(
                        !isDragging
                            && !SidebarDragPolicy.blocksMainInteraction(
                                isAnimating: motion.isAnimating
                            )
                    )
                    .overlay {
                        if motion.isPresented {
                            Button {
                                motion.setSidebarPresented(false)
                            } label: {
                                Color.black.opacity(0.001)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Close sidebar")
                            .accessibilityIdentifier("button.sidebar.dismiss")
                        }
                    }
                    #if SKIP
                    .background(Color.primary.opacity(0.04))
                    #else
                    .background(.ultraThinMaterial)
                    #endif
                    .clipShape(RoundedRectangle(cornerRadius: 40.0 * progress))
                    .shadow(color: Color.black.opacity(0.18), radius: 16, x: -6)
                    .offset(x: contentOffset)
            }
            #if SKIP
            .simultaneousGesture(dragGesture(sidebarWidth: width))
            #else
            .simultaneousGesture(
                dragGesture(sidebarWidth: width),
                isEnabled: activationAllowed
            )
            #endif
            .sensoryFeedback(.impact(weight: .light), trigger: motion.isPresented)
        }
        .platformFullScreenSidebarShell()
    }

    private var activationAllowed: Bool {
        motion.isPresented || activationAvailable
    }

    private func dragGesture(sidebarWidth: CGFloat) -> some Gesture {
        #if SKIP
        let gesture = DragGesture(minimumDistance: SidebarDragPolicy.minimumDistance)
        #else
        let gesture = DragGesture(
            minimumDistance: SidebarDragPolicy.minimumDistance,
            coordinateSpace: .global
        )
        #endif
        return gesture
            .onChanged { value in
                if activationAllowed, SidebarDragPolicy.accepts(
                    translationX: value.translation.width,
                    translationY: value.translation.height
                ) {
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        motion.dragOffset = SidebarDragPolicy.dragOffset(
                            isPresented: motion.isPresented,
                            translationX: value.translation.width
                        )
                    }
                } else {
                    motion.dragOffset = 0
                }
            }
            .onEnded { value in
                guard activationAllowed else {
                    motion.dragOffset = 0
                    return
                }
                motion.setSidebarPresented(SidebarDragPolicy.presentedAfterDrag(
                    isPresented: motion.isPresented,
                    translationX: value.translation.width,
                    translationY: value.translation.height,
                    predictedTranslationX: value.predictedEndTranslation.width,
                    sidebarWidth: sidebarWidth
                ))
            }
    }
}

private struct OutlinerBackIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

struct ContentView: View {
    private static let blockListTopID = "block-list-top"
    private static let blockListBottomID = "block-list-bottom"
    @State private var store: LogseqChatStore
    @State private var authentication: LogseqAuthenticationStore
    private let syncCoordinator: GraphSyncCoordinator
    @State private var composerExpanded = false
    @State private var handledCaptureRequestRevision = 0
    @State private var settingsPresented = false
    @State private var syncStatusPresented = false
    @State private var searchPagePresented = false
    @State private var graphsPresented = false
    @State private var flashcardsPresented = false
    @State private var graphPasswordPresented = false
    @State private var graphPassword = ""
    @State private var createGraphPresented = false
    @State private var newGraphName = ""
    @State private var newGraphEncrypted = true
    @State private var creatingGraph = false
    @State private var graphUnlockInProgress = false
    @State private var fileImporterPresented = false
    @State private var pendingAssetTargetBlockID: String?
    #if SKIP
    @State private var androidAudioRecorderPresented = false
    @State private var androidAudioRecorderTargetBlockID: String?
    #endif
    @State private var selectedTaskStatus: LogseqTaskStatus?
    @State private var editingBlock: LogseqBlock?
    @State private var blocksPendingDeletion: [LogseqBlock] = []
    @State private var pagePendingDeletion: LogseqSidebarPage?
    @State private var outlinerDeleteConfirmationPending = false
    @State private var sidebarMotion = SidebarMotionState()
    @State private var appNavigationPath: [AppNavigationRoute] = []
    @State private var pendingNodeRoutes: Set<AppNavigationRoute> = []
    @State private var nodeNavigationPreviews: [String: NodeNavigationPreview] = [:]
    #if !SKIP
    @State private var taskStatusPickerPresented = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var photoPickerPresented = false
    #if os(iOS)
    @State private var cameraPresented = false
    @State private var audioRecorderPresented = false
    @State private var audioRecorderTargetBlockID: String?
    @State private var previewAssetURL: URL?
    @State private var nodeSharePayload: NodeSharePayload?
    #endif
    #endif
    @State private var hasAutoScrolledInitially = false
    @State private var hasStartedContentTask = false
    @State private var isLoadingGraph = true
    @State private var draft = ""
    @AppStorage("logseq.baseURL") private var baseURL = "http://127.0.0.1:8787"
    @AppStorage("logseq.selectedGraphId") private var selectedGraphID = ""
    @AppStorage("logseq.composerDraft") private var persistedDraft = ""
    @AppStorage("logseq.appearance") private var appearance = "system"
    @AppStorage("logseq.language") private var language = "system"
    @FocusState private var composerFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    init(
        store: LogseqChatStore,
        authentication: LogseqAuthenticationStore,
        syncCoordinator: GraphSyncCoordinator
    ) {
        _store = State(initialValue: store)
        _authentication = State(initialValue: authentication)
        self.syncCoordinator = syncCoordinator
    }

    private var preferredLocale: Locale {
        language == "system" ? Locale.current : Locale(identifier: language)
    }

    private var themePalette: LogseqThemePalette {
        LogseqThemePolicy.palette(
            mode: LogseqThemeMode(rawValue: appearance) ?? .system,
            systemIsDark: colorScheme == .dark
        )
    }

    var body: some View {
        rootContent
        .preferredColorScheme(
            appearance == "light" ? .light : (appearance == "dark" ? .dark : nil)
        )
        .environment(\.locale, preferredLocale)
        .tint(LogseqThemePolicy.accent)
        .foregroundStyle(themePalette.primaryText)
        .background(themePalette.background.ignoresSafeArea())
        .onAppear {
            applyCaptureRequestIfNeeded()
        }
        .task {
            for await available in NetworkAvailabilityStream.values() {
                await syncCoordinator.setNetworkAvailable(available)
            }
        }
        .task {
            if !hasStartedContentTask {
                hasStartedContentTask = true
                draft = persistedDraft
                #if DEBUG
                print("LogseqChat debug: content task started")
                #endif
                let graphLoadStartedAt = Date()
                await LogseqChatRuntime.shared.waitForLocalLaunchLoad()
                #if DEBUG
                print("LogseqChat debug: local store opened")
                #endif
                let graphLoadMilliseconds = Date()
                    .timeIntervalSince(graphLoadStartedAt) * 1_000
                isLoadingGraph = false
                #if DEBUG
                print(
                    "LogseqChat debug: graph loaded "
                        + "ms=\(String(format: "%.2f", graphLoadMilliseconds))"
                )
                #endif
                await authentication.restore()
                #if DEBUG
                print("LogseqChat debug: authentication restore finished state=\(authentication.state.rawValue)")
                #endif
                connectWithCurrentAccessToken()
            }
            await store.runPendingSyncLoop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, authentication.state == .signedIn {
                connectWithCurrentAccessToken()
            }
        }
        .onChange(of: store.snapshot.selectedGraphId) { _, graphID in
            guard let graphID, !graphID.isEmpty else { return }
            selectedGraphID = graphID
            guard authentication.state == .signedIn else { return }
            beginGraphAccess(graphID)
        }
        .onChange(of: store.snapshot.outlinerCommandRevision) { _, _ in
            performOutlinerPlatformCommands()
        }
        .onChange(of: store.captureRequestRevision) { _, _ in
            applyCaptureRequestIfNeeded()
        }
        .sheet(isPresented: $settingsPresented) {
            ConnectionSettingsView(
                baseURL: $baseURL,
                graphDatabasePath: selectedGraphDatabasePath,
                apply: {
                    settingsPresented = false
                    connectWithCurrentAccessToken()
                },
                signOut: {
                    settingsPresented = false
                    Task {
                        await syncCoordinator.stopForeground()
                        await authentication.signOut()
                        selectedGraphID = ""
                        store.configure(baseURL: baseURL, token: "", refreshAfterApply: false)
                    }
                }
            )
        }
        .sheet(isPresented: $syncStatusPresented) {
            SyncStatusView(
                graphName: syncStatusGraphName,
                summary: syncStatusSummary,
                isConnected: syncConnectionAvailable,
                hasPendingChanges: hasUnconfirmedSyncChanges,
                cursor: store.snapshot.appliedServerT,
                errorMessage: store.syncError?.message ?? presentedError?.message,
                syncNow: { store.syncPending() },
                close: { syncStatusPresented = false }
            )
        }
        .sheet(isPresented: $searchPagePresented) {
            NodeSearchView(store: store) { hit in
                #if SKIP
                store.openNode(hit.uuid)
                #else
                openNodeRoute(hit.uuid)
                #endif
            }
        }
        #if !SKIP && os(iOS)
        .sheet(item: $nodeSharePayload) { payload in
            NodeShareSheet(items: payload.items)
        }
        #endif
        .sheet(isPresented: $graphPasswordPresented) {
            NavigationStack {
                Form {
                    SecureField("E2EE password", text: $graphPassword)
                        .textContentType(.password)
                    if let error = presentedError {
                        Text(verbatim: error.message)
                            .foregroundStyle(.red)
                    }
                }
                .navigationTitle("Unlock encrypted graphs")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            graphPasswordPresented = false
                            graphPassword = ""
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Unlock") {
                            unlockSelectedGraph()
                        }
                        .disabled(graphPassword.isEmpty || graphUnlockInProgress)
                    }
                }
            }
        }
        .sheet(isPresented: $createGraphPresented) {
            NavigationStack {
                Form {
                    TextField("Graph name", text: $newGraphName)
                        .accessibilityIdentifier("field.graph-name")
                    Toggle("End-to-end encryption", isOn: $newGraphEncrypted)
                        .accessibilityIdentifier("toggle.graph-encryption")
                    Text("Encryption cannot be changed after the sync graph is created.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let error = presentedError {
                        Text(verbatim: error.message)
                            .foregroundStyle(.red)
                    }
                }
                .navigationTitle("Add sync graph")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { createGraphPresented = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            creatingGraph = true
                            Task {
                                if await store.createSyncGraph(
                                    name: newGraphName,
                                    isEncrypted: newGraphEncrypted
                                ) {
                                    createGraphPresented = false
                                    newGraphName = ""
                                }
                                creatingGraph = false
                            }
                        }
                        .disabled(
                            creatingGraph
                                || newGraphName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        .accessibilityIdentifier("button.graph-add.confirm")
                    }
                }
            }
        }
        .alert(
            blocksPendingDeletion.count > 1 ? "Delete blocks?" : "Delete block?",
            isPresented: deleteConfirmationPresented
        ) {
            Button("Delete", role: .destructive) {
                if outlinerDeleteConfirmationPending {
                    store.outlinerEvent(LogseqOutlinerEvent(type: "confirmDelete"))
                } else if blocksPendingDeletion.count == 1, let block = blocksPendingDeletion.first {
                    store.delete(block: block)
                }
                blocksPendingDeletion = []
                outlinerDeleteConfirmationPending = false
            }
            Button("Cancel", role: .cancel) {
                blocksPendingDeletion = []
                outlinerDeleteConfirmationPending = false
            }
        } message: {
            Text(verbatim: "This deletes the block and all of its children. Pages use Recycle instead.")
        }
        .alert("Delete page?", isPresented: pageDeleteConfirmationPresented) {
            Button("Delete", role: .destructive) {
                guard let page = pagePendingDeletion else { return }
                let closesNodeRoute = isNodePagePresented
                store.deletePage(pageUUID: page.uuid)
                pagePendingDeletion = nil
                if closesNodeRoute {
                    #if SKIP
                    store.closeNode()
                    #else
                    appNavigationPath = OutlinerNavigationPolicy.pathAfterBackButton(
                        appNavigationPath
                    )
                    #endif
                } else {
                    store.clearSelectedPage()
                }
            }
            Button("Cancel", role: .cancel) {
                pagePendingDeletion = nil
            }
        } message: {
            Text("The page will be moved to Recycle.")
        }
        #if !SKIP
        .fileImporter(
            isPresented: $fileImporterPresented,
            allowedContentTypes: [.image, .audio, .data],
            allowsMultipleSelection: true
        ) { result in
            importAssets(result)
        }
        .photosPicker(
            isPresented: $photoPickerPresented,
            selection: $selectedPhotoItems,
            maxSelectionCount: 20,
            matching: .images
        )
        #if os(iOS)
        .fullScreenCover(isPresented: $cameraPresented) {
            CameraPicker { image in
                cameraPresented = false
                importCapturedPhoto(image)
            } onCancel: {
                cameraPresented = false
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $audioRecorderPresented) {
            AudioRecorderSheet(targetBlockID: audioRecorderTargetBlockID) { asset, targetBlockID in
                let assetUUID = store.addAsset(
                    title: asset.title,
                    assetType: AudioRecordingPolicy.fileExtension,
                    assetSize: asset.size,
                    assetChecksum: asset.checksum,
                    localPath: LocalAssetPath.storedPath(asset.path),
                    targetBlockId: targetBlockID
                )
                audioRecorderTargetBlockID = nil
                return assetUUID
            } onTranscript: { assetUUID, transcript in
                store.addChildBlock(transcript, parentId: assetUUID)
            }
        }
        .quickLookPreview($previewAssetURL)
        #endif
        .onChange(of: selectedPhotoItems) { _, items in
            importPhotos(items)
        }
        #endif
        #if SKIP
        .sheet(isPresented: $androidAudioRecorderPresented) {
            AndroidAudioRecorderSheet(targetBlockID: androidAudioRecorderTargetBlockID) {
                title, type, size, checksum, path, targetBlockID in
                let assetUUID = store.addAsset(
                    title: title,
                    assetType: type,
                    assetSize: size,
                    assetChecksum: checksum,
                    localPath: path,
                    targetBlockId: targetBlockID
                )
                androidAudioRecorderTargetBlockID = nil
                return assetUUID
            } onTranscript: { assetUUID, transcript in
                store.addChildBlock(transcript, parentId: assetUUID)
            }
        }
        #endif
    }

    private func applyCaptureRequestIfNeeded() {
        guard store.captureRequestRevision > handledCaptureRequestRevision else { return }
        handledCaptureRequestRevision = store.captureRequestRevision
        graphsPresented = false
        flashcardsPresented = false
        expandComposer()
    }

    @ViewBuilder
    private var rootContent: some View {
        authenticatedContent
    }

    private var graphPicker: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(verbatim: "Choose a graph")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Spacer()
                settingsControl
            }
            Text(verbatim: "Select a Logseq graph to download and sync on this device.")
                .foregroundStyle(.secondary)
            Button {
                createGraphPresented = true
            } label: { Text("Add sync graph") }
            .accessibilityIdentifier("button.graph-add")
            if let message = authentication.errorMessage {
                Text(verbatim: message)
                    .foregroundStyle(.red)
            }
            if let error = presentedError {
                ErrorBanner(error: error)
            }

            let graphs = store.snapshot.graphs ?? []
            if graphs.isEmpty {
                if store.isRefreshing {
                    ProgressView()
                } else {
                    Button("Refresh graphs") {
                        store.refresh()
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(graphs) { graph in
                            Button {
                                Task { await openManagedGraph(graph) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(verbatim: graph.name)
                                            .fontWeight(.semibold)
                                        if graph.isEncrypted {
                                            Text(verbatim: "Encrypted")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        } else if !graph.isReady {
                                            Text(verbatim: "Graph is not ready for sync.")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(themePalette.surface)
                                .cornerRadius(16)
                            }
                            .disabled(!graph.isReady)
                            .accessibilityIdentifier("graph.\(graph.id)")
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(appBackground)
        .accessibilityIdentifier("screen.graph-picker")
    }

    private var appShell: some View {
        SidebarMotionShell(
            motion: sidebarMotion,
            activationAvailable: sidebarActivationAvailable,
            sidebar: sidebarContent,
            main: sidebarMainPage
        )
    }

    @ViewBuilder private var sidebarMainPage: some View {
        #if SKIP
            mainContent
        #else
        NavigationStack(path: $appNavigationPath) {
            navigationMainContent
                .navigationDestination(for: AppNavigationRoute.self) { route in
                    appNavigationDestination(route)
                }
        }
        .onChange(of: appNavigationPath) { previousPath, path in
            let closedNodes = AppNavigationPathPolicy.coreCloseCount(
                previousPath: previousPath,
                path: path,
                projectedNodeCount: store.snapshot.nodeRoutes.count
            )
            if closedNodes > 0 {
                for _ in 0..<closedNodes { store.closeNode() }
            }
            let activeNodeIDs = Set(path.map { route in
                switch route { case let .node(uuid): uuid }
            })
            nodeNavigationPreviews = nodeNavigationPreviews.filter {
                activeNodeIDs.contains($0.key)
            }
        }
        #if os(iOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if BottomChromePolicy.occupiesLayoutSpace(bottomChromePresentation) {
                iosBottomChrome
            }
        }
        .overlay(alignment: .bottom) {
            if !BottomChromePolicy.occupiesLayoutSpace(bottomChromePresentation) {
                iosBottomChrome
            }
        }
        #endif
        #endif
    }

    #if !SKIP
    @ViewBuilder private func appNavigationDestination(_ route: AppNavigationRoute) -> some View {
        switch route {
        case let .node(uuid): nodeNavigationDestination(uuid: uuid)
        }
    }

    private func nodeNavigationDestination(uuid: String) -> some View {
        Group {
            if let projection = store.snapshot.nodeRoutes.last(where: { $0.uuid == uuid }) {
                nodeProjectionContent(projection)
            } else if let preview = nodeNavigationPreviews[uuid] {
                nodeNavigationPreviewContent(preview)
            } else {
                Color.clear
            }
        }
        .background(appBackground)
        .navigationTitle(nodeProjectionTitle(uuid: uuid))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                syncIndicatorControl
                settingsControl
            }
        }
        #endif
    }

    private func nodeNavigationPreviewContent(_ preview: NodeNavigationPreview) -> some View {
        OutlinerView(
            rows: preview.rows,
            sections: preview.sections,
            editing: nil,
            selectedBlockIDs: [],
            statuses: availableTaskStatuses,
            error: nil,
            hasOlderJournals: false,
            topPadding: 16,
            bottomPadding: blockListContentBottomPadding,
            sendEvent: { _ in },
            onBeginInteraction: {},
            onZoomBlock: openOutlinerNode,
            onOpenMarkupLink: openMarkupLink,
            onLoadOlderJournals: {},
            relatedTitle: nil,
            relatedEmptyTitle: nil,
            relatedBlocks: [],
            relatedAccessibilityIdentifier: "section.node.linked-references",
            linkedReferenceBlocks: [],
            showsEmptyPlaceholder: false,
            onAddFirstBlock: nil,
            isJournalHome: false
        )
    }

    @ViewBuilder private func nodeProjectionContent(_ projection: LogseqNodeProjection) -> some View {
        OutlinerView(
            rows: projection.outlinerRows,
            sections: store.sections(for: projection),
            editing: projection.outlinerState.editing,
            selectedBlockIDs: Set(projection.outlinerState.selectedBlockIds),
            statuses: availableTaskStatuses,
            error: presentedError,
            hasOlderJournals: false,
            topPadding: 16,
            bottomPadding: blockListContentBottomPadding,
            sendEvent: store.outlinerEvent,
            onBeginInteraction: beginOutlinerInteraction,
            onZoomBlock: openOutlinerNode,
            onOpenMarkupLink: openMarkupLink,
            onLoadOlderJournals: {},
            relatedTitle: RelatedContentPolicy.sectionTitle(
                isTag: projection.isTag,
                hasBlocks: !projection.relatedBlocks.isEmpty
            ),
            relatedEmptyTitle: RelatedContentPolicy.emptyTitle(
                isTag: projection.isTag,
                hasBlocks: !projection.relatedBlocks.isEmpty
            ),
            relatedBlocks: projection.relatedBlocks,
            relatedAccessibilityIdentifier: projection.isTag
                ? "section.tag.tagged-nodes" : "section.node.linked-references",
            linkedReferenceBlocks: projection.linkedReferenceBlocks,
            showsEmptyPlaceholder: false,
            onAddFirstBlock: nodeAddFirstBlock(projection),
            isJournalHome: false
        )
    }

    private func nodeAddFirstBlock(_ projection: LogseqNodeProjection) -> (() -> Void)? {
        guard !projection.isTag, !projection.isProperty else { return nil }
        return {
            store.outlinerEvent(
                LogseqOutlinerEvent(type: "addRootBlock", uuid: projection.page.uuid)
            )
        }
    }

    private func nodeProjectionTitle(uuid: String) -> String {
        guard let projection = store.snapshot.nodeRoutes.last(where: { $0.uuid == uuid }) else {
            return nodeNavigationPreviews[uuid]?.title
                ?? markupTargetTitle(uuid: uuid)
                ?? "Untitled"
        }
        if projection.isTag { return "#\(projection.page.title)" }
        return projection.blocks.first(where: { $0.uuid == uuid })?.title ?? projection.page.title
    }

    @ViewBuilder private var navigationMainContent: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            primaryContent
                .background(appBackground)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    nativeHeaderToolbar
                }
        } else {
            mainContent
                .platformRootNavigationChromeHidden()
        }
        #else
        mainContent
            .platformRootNavigationChromeHidden()
        #endif
    }

    #if os(iOS)
    @available(iOS 26.0, *)
    @ToolbarContentBuilder private var nativeHeaderToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            headerLeadingControl
                .buttonBorderShape(.circle)
        }
        ToolbarItem(placement: .principal) {
            headerTitle
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            syncIndicatorControl
            settingsControl
        }
    }
    #endif
    #endif

    private var sidebarContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Menu {
                    ForEach(store.snapshot.graphs ?? []) { graph in
                        Button {
                            switchGraph(to: graph)
                        } label: {
                            Text(verbatim: graph.name)
                        }
                        .disabled(!graph.isReady)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(verbatim: graphSubtitle)
                            .font(.title3)
                            .fontWeight(.bold)
                            .lineLimit(1)
                            // Menus tint their label with the accent color;
                            // the graph name should read as a heading.
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 12)
                }
                .accessibilityLabel("Switch graph")
                .accessibilityIdentifier("button.graph-switch")
                .tint(.primary)
                .padding(.bottom, 16)

                ForEach(SidebarContentItem.allCases, id: \.rawValue) { item in
                    sidebarItem(item)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            #if SKIP
            .padding(.top, SidebarChromeMetrics.androidHeaderTopPadding)
            #else
            .padding(.top, SidebarChromeMetrics.iOSHeaderTopPadding)
            #endif
        }
    }

    private var journalsIsCurrentDestination: Bool {
        !graphsPresented && !flashcardsPresented && store.snapshot.selectedPage == nil
    }

    @ViewBuilder private func sidebarItem(_ item: SidebarContentItem) -> some View {
        switch item {
        case .journals:
            sidebarRow(
                title: item.title,
                systemImage: "calendar",
                isSelected: journalsIsCurrentDestination,
                identifier: item.accessibilityIdentifier
            ) {
                openJournals()
            }
        case .flashcards:
            sidebarRow(
                title: item.title,
                assetImage: "flashcards",
                isSelected: flashcardsPresented,
                identifier: item.accessibilityIdentifier
            ) {
                openFlashcards()
            }
        case .graphs:
            sidebarRow(
                title: item.title,
                systemImage: "folder",
                isSelected: graphsPresented,
                identifier: item.accessibilityIdentifier
            ) {
                openGraphs()
            }
        case .favorites:
            sidebarSection(
                title: item.title,
                systemImage: "star",
                identifier: item.accessibilityIdentifier,
                emptyTitle: "No favorites yet",
                pages: store.snapshot.favorites
            )
        case .recent:
            sidebarSection(
                title: item.title,
                systemImage: "clock",
                identifier: item.accessibilityIdentifier,
                emptyTitle: "No recent pages",
                pages: store.snapshot.recentPages
            )
        }
    }

    private func sidebarRow(
        title: String,
        systemImage: String? = nil,
        assetImage: String? = nil,
        isSelected: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let assetImage {
                        IconImage(name: assetImage, size: 18)
                    } else if let systemImage {
                        Image(systemName: systemImage)
                            .font(.subheadline)
                    }
                }
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 22)
                Text(verbatim: title)
                    .font(.body)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.black.opacity(0.001)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func sidebarSection(
        title: String,
        systemImage: String,
        identifier: String,
        emptyTitle: String,
        pages: [LogseqSidebarPage]
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption2)
                Text(verbatim: title)
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 6)
            if pages.isEmpty {
                Text(verbatim: emptyTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .opacity(0.7)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            ForEach(pages) { page in
                sidebarRow(
                    title: page.title,
                    systemImage: "doc.text",
                    isSelected: store.snapshot.selectedPage?.uuid == page.uuid,
                    identifier: "link.sidebar.page.\(page.uuid)"
                ) {
                    openSidebarPage(page)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(identifier)
    }

    private func switchGraph(to graph: LogseqGraph) {
        guard sidebarMotion.isPresented,
              abs(sidebarMotion.dragOffset) == 0.0 else { return }
        sidebarMotion.setSidebarPresented(false)
        if graph.id == store.snapshot.selectedGraphId {
            store.clearSelectedPage()
            return
        }
        selectedGraphID = graph.id
        store.selectGraph(graph.id)
    }

    private func openSidebarPage(_ page: LogseqSidebarPage) {
        guard sidebarMotion.isPresented,
              abs(sidebarMotion.dragOffset) == 0.0 else { return }
        sidebarMotion.setSidebarPresented(false)
        graphsPresented = false
        flashcardsPresented = false
        store.selectPage(page.uuid)
    }

    private func openJournals() {
        guard sidebarMotion.isPresented,
              abs(sidebarMotion.dragOffset) == 0.0 else { return }
        sidebarMotion.setSidebarPresented(false)
        graphsPresented = false
        flashcardsPresented = false
        store.clearSelectedPage()
    }

    private func openFlashcards() {
        guard sidebarMotion.isPresented,
              abs(sidebarMotion.dragOffset) == 0.0 else { return }
        sidebarMotion.setSidebarPresented(false)
        graphsPresented = false
        flashcardsPresented = true
        store.clearSelectedPage()
    }

    private func openGraphs() {
        guard sidebarMotion.isPresented,
              abs(sidebarMotion.dragOffset) == 0.0 else { return }
        sidebarMotion.setSidebarPresented(false)
        flashcardsPresented = false
        graphsPresented = true
    }

    private func openManagedGraph(_ graph: LogseqGraph) async {
        if graph.id == store.snapshot.selectedGraphId,
           LogseqGraphLocalStorage.isDownloaded(databasePath: databasePath, graphID: graph.id) {
            guard await store.clearSelectedPageAndWait() else { return }
            graphsPresented = false
            flashcardsPresented = false
            return
        }
        selectedGraphID = graph.id
        guard await store.selectGraphAndWait(graph.id) else { return }
        graphsPresented = false
        flashcardsPresented = false
    }

    private func deleteManagedGraph(_ graph: LogseqGraph) async throws {
        let deletingSelectedGraph = graph.id == selectedGraphID || graph.id == store.snapshot.selectedGraphId
        if deletingSelectedGraph {
            await syncCoordinator.stopForeground()
            await store.resetToCatalog()
        }
        try LogseqGraphLocalStorage.delete(databasePath: databasePath, graphID: graph.id)
        guard deletingSelectedGraph else { return }
        selectedGraphID = ""
        let accessToken = try await authentication.accessToken()
        await store.configureAndSelectGraph(
            baseURL: baseURL,
            token: accessToken,
            selectedGraphID: nil
        )
    }

    private var sidebarActivationAvailable: Bool {
        SidebarDragPolicy.allowsActivation(
            isPresented: false,
            isEditingOutlinerBlock: outlinerEditing != nil,
            hasOutlinerSelection: !outlinerSelectedBlockIDs.isEmpty,
            hasPresentedNavigation: !appNavigationPath.isEmpty
        )
    }

    @ViewBuilder private var mainContent: some View {
        #if SKIP
        stackedContent
            .overlay(alignment: .bottom) {
                androidFloatingControls
            }
        #elseif os(macOS)
        stackedContent
            .overlay(alignment: .bottom) {
                if shouldShowComposer {
                    floatingComposer
                        .platformFloatingComposerInset()
                }
            }
        #else
        stackedContent
        #endif
    }

    @ViewBuilder private var stackedContent: some View {
        #if os(iOS) && !SKIP
        ZStack(alignment: .top) {
            primaryContent
                .safeAreaInset(edge: .top, spacing: 0) {
                    Color.clear.frame(height: SidebarChromeMetrics.headerHeight)
                }
            header
                .platformContinuousHeaderChrome()
        }
        .background(appBackground)
        #else
        ZStack(alignment: .top) {
            primaryContent
            header
                .platformLegacyHeaderChrome()
        }
        .background(appBackground)
        #endif
    }

    @ViewBuilder private var primaryContent: some View {
        if graphsPresented {
            GraphsView(
                graphs: store.snapshot.graphs ?? [],
                databasePath: databasePath,
                refresh: { store.refresh() },
                add: { createGraphPresented = true },
                open: { graph in Task { await openManagedGraph(graph) } },
                deleteGraph: deleteManagedGraph
            )
        } else if flashcardsPresented {
            FlashcardsView(
                cards: store.snapshot.flashcards,
                load: { store.loadFlashcards() },
                review: { card, rating in
                    store.reviewFlashcard(uuid: card.block.uuid, rating: rating)
                }
            )
        } else if let projection = activeSkipNodeProjection {
            skipNodeProjectionContent(projection)
        } else {
            if presentedContentMode == .outliner {
                OutlinerView(
                    rows: store.snapshot.outlinerRows,
                    sections: store.sections(for: LogseqContentMode.outliner),
                    editing: presentedOutlinerEditing,
                    selectedBlockIDs: outlinerSelectedBlockIDs,
                    statuses: availableTaskStatuses,
                    error: presentedError,
                    hasOlderJournals: store.snapshot.selectedPage == nil
                        && store.snapshot.hasOlderJournals,
                    topPadding: blockListContentTopPadding,
                    bottomPadding: blockListContentBottomPadding,
                    sendEvent: store.outlinerEvent,
                    onBeginInteraction: beginOutlinerInteraction,
                    onZoomBlock: openOutlinerNode,
                    onOpenMarkupLink: openMarkupLink,
                    onLoadOlderJournals: store.loadOlderJournals,
                    relatedTitle: selectedPageRelatedTitle,
                    relatedEmptyTitle: selectedPageRelatedEmptyTitle,
                    relatedBlocks: selectedPageRelatedBlocks,
                    relatedAccessibilityIdentifier: selectedPageRelatedAccessibilityIdentifier,
                    linkedReferenceBlocks: store.snapshot.linkedReferenceBlocks ?? [],
                    showsEmptyPlaceholder: store.snapshot.selectedPage == nil
                        && !isLoadingGraph,
                    onAddFirstBlock: selectedPageAddFirstBlock,
                    isJournalHome: store.snapshot.selectedPage == nil
                )
            } else {
                blockList
            }
        }
    }

    private var activeSkipNodeProjection: LogseqNodeProjection? {
        #if SKIP
        store.snapshot.nodeRoutes.last
        #else
        nil
        #endif
    }

    private var activeNodeProjection: LogseqNodeProjection? {
        store.snapshot.nodeRoutes.last
    }

    @ViewBuilder private func skipNodeProjectionContent(_ projection: LogseqNodeProjection) -> some View {
        OutlinerView(
            rows: projection.outlinerRows,
            sections: store.sections(for: projection),
            editing: projection.outlinerState.editing,
            selectedBlockIDs: Set(projection.outlinerState.selectedBlockIds),
            statuses: availableTaskStatuses,
            error: presentedError,
            hasOlderJournals: false,
            topPadding: blockListContentTopPadding,
            bottomPadding: blockListContentBottomPadding,
            sendEvent: store.outlinerEvent,
            onBeginInteraction: beginOutlinerInteraction,
            onZoomBlock: openOutlinerNode,
            onOpenMarkupLink: openMarkupLink,
            onLoadOlderJournals: {},
            relatedTitle: RelatedContentPolicy.sectionTitle(
                isTag: projection.isTag,
                hasBlocks: !projection.relatedBlocks.isEmpty
            ),
            relatedEmptyTitle: RelatedContentPolicy.emptyTitle(
                isTag: projection.isTag,
                hasBlocks: !projection.relatedBlocks.isEmpty
            ),
            relatedBlocks: projection.relatedBlocks,
            relatedAccessibilityIdentifier: projection.isTag
                ? "section.tag.tagged-nodes" : "section.node.linked-references",
            linkedReferenceBlocks: projection.linkedReferenceBlocks,
            showsEmptyPlaceholder: false,
            onAddFirstBlock: (!projection.isTag && !projection.isProperty) ? {
                store.outlinerEvent(
                    LogseqOutlinerEvent(type: "addRootBlock", uuid: projection.page.uuid)
                )
            } : nil,
            isJournalHome: false
        )
    }

    // Sidebar pages keep the original selected-page interaction while showing
    // the same related content as node projections.
    private var selectedPageRelatedBlocks: [LogseqBlock] {
        guard store.snapshot.selectedPage != nil else { return [] }
        return store.snapshot.relatedBlocks ?? []
    }

    private var selectedPageRelatedTitle: String? {
        RelatedContentPolicy.sectionTitle(
            isTag: store.snapshot.selectedPageIsTag == true,
            hasBlocks: !selectedPageRelatedBlocks.isEmpty
        )
    }

    private var selectedPageRelatedEmptyTitle: String? {
        RelatedContentPolicy.emptyTitle(
            isTag: store.snapshot.selectedPageIsTag == true,
            hasBlocks: !selectedPageRelatedBlocks.isEmpty
        )
    }

    private var selectedPageRelatedAccessibilityIdentifier: String {
        store.snapshot.selectedPageIsTag == true
            ? "section.tag.tagged-nodes" : "section.node.linked-references"
    }

    // Empty non-tag, non-property pages offer to create and edit their first
    // block in place.
    private var selectedPageAddFirstBlock: (() -> Void)? {
        guard let selectedPage = store.snapshot.selectedPage,
              store.snapshot.selectedPageIsTag != true,
              store.snapshot.selectedPageIsProperty != true else { return nil }
        return {
            store.outlinerEvent(
                LogseqOutlinerEvent(type: "addRootBlock", uuid: selectedPage.uuid)
            )
        }
    }

    private func markupTargetTitle(uuid: String) -> String? {
        let blocks = store.snapshot.blocks + store.snapshot.nodeRoutes.flatMap(\.blocks)
        for block in blocks {
            if let target = (block.references + block.tags).first(where: { $0.uuid == uuid }) {
                return target.title
            }
        }
        return nil
    }

    private func beginOutlinerInteraction() {
        composerExpanded = false
        composerFocused = false
        editingBlock = nil
    }

    private func openMarkupLink(_ link: OutlinerMarkupLink) {
        switch link {
        case let .node(uuid):
            #if SKIP
            store.openNode(uuid)
            #else
            openNodeRoute(uuid)
            #endif
        }
    }

    private func openOutlinerNode(_ uuid: String) {
        #if SKIP
        store.outlinerEvent(LogseqOutlinerEvent(type: "zoomIn", uuid: uuid))
        #else
        openNodeRoute(uuid)
        #endif
    }

    #if !SKIP
    private func openNodeRoute(_ uuid: String) {
        let route = AppNavigationRoute.node(uuid)
        guard AppNavigationPathPolicy.shouldAppend(route, to: appNavigationPath),
              !pendingNodeRoutes.contains(route)
        else {
            #if DEBUG
            print("LogseqChat debug: ignored duplicate node route target=\(route)")
            #endif
            return
        }
        #if DEBUG
        print("LogseqChat debug: opening node route target=\(route) currentDepth=\(appNavigationPath.count)")
        #endif
        let previewSource = activeNodeProjection
        nodeNavigationPreviews[uuid] = NodeNavigationPreviewPolicy.make(
            uuid: uuid,
            rows: previewSource?.outlinerRows ?? store.snapshot.outlinerRows,
            sections: previewSource.map(store.sections(for:))
                ?? store.sections(for: LogseqContentMode.outliner),
            linkedTitle: markupTargetTitle(uuid: uuid)
        )
        pendingNodeRoutes.insert(route)
        let requestedPath = AppNavigationPathPolicy.pathAfterRequest(
            route,
            in: appNavigationPath
        )
        let requestedDepth = requestedPath.count
        appNavigationPath = requestedPath
        store.openNode(uuid) { resolved in
            pendingNodeRoutes.remove(route)
            if !resolved { nodeNavigationPreviews.removeValue(forKey: uuid) }
            if resolved,
               !AppNavigationPathPolicy.shouldKeepResolvedProjection(
                   route,
                   requestedDepth: requestedDepth,
                   in: appNavigationPath
               ) {
                store.closeNode()
                return
            }
            appNavigationPath = AppNavigationPathPolicy.pathAfterResolution(
                route,
                resolved: resolved,
                in: appNavigationPath
            )
        }
    }
    #endif

    private var shouldShowComposer: Bool {
        !graphsPresented
            && !flashcardsPresented
            && (store.snapshot.selectedPage == nil || isNodePagePresented)
    }

    private var shouldShowExpandedComposer: Bool {
        shouldShowComposer && composerExpanded
    }

    private var bottomChromePresentation: BottomChromePresentation {
        BottomChromePolicy.presentation(
            contentMode: presentedContentMode,
            hasSelectedPage: store.snapshot.selectedPage != nil,
            composerExpanded: composerExpanded,
            hasOutlinerSelection: !outlinerSelectedBlockIDs.isEmpty,
            isEditingOutlinerBlock: presentedOutlinerEditing != nil,
            isNodePage: isNodePagePresented,
            showsComposer: shouldShowComposer
        )
    }

    private var isNodePagePresented: Bool {
        #if SKIP
        !store.snapshot.nodeRoutes.isEmpty
        #else
        !appNavigationPath.isEmpty
        #endif
    }

    private var graphSubtitle: String {
        if let graphName = store.snapshot.graphName, !graphName.isEmpty {
            return graphName
        }
        let graphID = store.snapshot.selectedGraphId ?? selectedGraphID
        return graphID.isEmpty ? "Choose a graph" : graphID
    }

    private var contentMode: LogseqContentMode {
        LogseqContentMode.defaultMode
    }

    private var presentedContentMode: LogseqContentMode {
        contentMode.presentationMode(
            hasSelectedPage: store.snapshot.selectedPage != nil
        )
    }

    private var favoriteTargetPage: LogseqSidebarPage? {
        guard !graphsPresented, !flashcardsPresented else { return nil }
        return activeNodeProjection?.page ?? store.snapshot.selectedPage
    }

    private var favoriteTargetIsFavorite: Bool {
        guard let target = favoriteTargetPage else { return false }
        return store.snapshot.favorites.contains(where: { $0.uuid == target.uuid })
    }

    private var outlinerEditing: LogseqOutlinerEditing? {
        activeNodeProjection?.outlinerState.editing ?? store.snapshot.outlinerState.editing
    }

    private var presentedOutlinerEditing: LogseqOutlinerEditing? {
        outlinerEditing
    }

    private var outlinerSelectedBlockIDs: Set<String> {
        Set(activeNodeProjection?.outlinerState.selectedBlockIds
            ?? store.snapshot.outlinerState.selectedBlockIds)
    }

    private var zoomedOutlinerBlock: LogseqBlock? {
        guard presentedContentMode == .outliner,
              let id = (activeNodeProjection?.outlinerState
                ?? store.snapshot.outlinerState).zoomedBlockId else { return nil }
        return (activeNodeProjection?.blocks ?? store.snapshot.blocks)
            .first(where: { $0.uuid == id })
    }

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { !blocksPendingDeletion.isEmpty },
            set: { if !$0 { blocksPendingDeletion = [] } }
        )
    }

    private var pageDeleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pagePendingDeletion != nil },
            set: { if !$0 { pagePendingDeletion = nil } }
        )
    }

    private func nodeShareText(_ page: LogseqSidebarPage) -> String {
        NodeSharePolicy.text(pageTitle: page.title, blocks: nodeShareBlocks)
    }

    private var nodeShareBlocks: [LogseqBlock] {
        activeNodeProjection?.blocks ?? store.snapshot.blocks
    }

    private var databasePath: String {
        LogseqChatRuntime.shared.databasePath
    }

    private var selectedGraphDatabasePath: String? {
        #if !SKIP
        let graphID = store.snapshot.selectedGraphId ?? selectedGraphID
        guard !graphID.isEmpty else { return nil }
        let databaseURL = LogseqGraphLocalStorage.directoryURL(
            databasePath: databasePath,
            graphID: graphID
        )
            .appendingPathComponent("graph.sqlite")
        return FileManager.default.fileExists(atPath: databaseURL.path) ? databaseURL.path : nil
        #else
        return nil
        #endif
    }

    private func connectWithCurrentAccessToken() {
        Task {
            do {
                #if DEBUG
                print("LogseqChat debug: requesting Cognito access token")
                #endif
                let accessToken = try await authentication.accessToken()
                #if DEBUG
                print("LogseqChat debug: access token acquired; configuring \(baseURL)")
                #endif
                logger.info("Configuring graph sync connection")
                let requestedGraphID = selectedGraphID
                await store.configureAndSelectGraph(
                    baseURL: baseURL,
                    token: accessToken,
                    selectedGraphID: requestedGraphID.isEmpty ? nil : requestedGraphID
                )
                if !requestedGraphID.isEmpty {
                    beginGraphAccess(requestedGraphID)
                }
            } catch {
                #if DEBUG
                print("LogseqChat debug: access token request failed: \(error.localizedDescription)")
                #endif
                logger.error("Could not acquire Cognito access token: \(error.localizedDescription)")
            }
        }
    }

    private func loadSelectedGraphFromDiskIfAvailable() async {
        guard !selectedGraphID.isEmpty else { return }
        await store.configureAndSelectGraph(
            baseURL: baseURL,
            token: "",
            selectedGraphID: selectedGraphID
        )
        if store.snapshot.isGraphEncrypted == true && store.snapshot.isGraphUnlocked != true {
            return
        }
        _ = await store.bootstrapSelectedGraph(
            graphID: selectedGraphID,
            baseURL: baseURL,
            accessToken: "",
            allowSnapshotDownload: false,
            isEncrypted: store.snapshot.graphs?.first(where: { $0.id == selectedGraphID })?.isEncrypted ?? false
        )
    }

    @ViewBuilder private var authenticatedContent: some View {
        if GraphLaunchPolicy.shouldShowPicker(
            snapshotSelectedGraphID: store.snapshot.selectedGraphId,
            persistedSelectedGraphID: selectedGraphID,
            isGraphsPresented: graphsDestinationPresented
        ) {
            graphPicker
        } else if isLoadingGraph, store.snapshot.blocks.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading journals")
                .accessibilityIdentifier("journals.loading")
        } else {
            ZStack(alignment: .topLeading) {
                appShell
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityLabel("Journal graph load status")
                    .accessibilityIdentifier("journals.graph-loaded")
                if !isLoadingGraph {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .onAppear {
                            LogseqChatAppDelegate.shared.onJournalsUIReady()
                        }
                }
            }
        }
    }

    private var graphsDestinationPresented: Bool {
        graphsPresented
    }

    private func startGraphSync(_ graphID: String) {
        Task {
            await syncCoordinator.startForeground(graphID: graphID) { graphID in
                guard let accessToken = try? await authentication.accessToken() else { return }
                let isEncrypted = store.snapshot.graphs?.first(where: { $0.id == graphID })?.isEncrypted ?? false
                guard await store.bootstrapSelectedGraph(
                    graphID: graphID,
                    baseURL: baseURL,
                    accessToken: accessToken,
                    isEncrypted: isEncrypted
                ) else { return }
                while !Task.isCancelled && authentication.state == .signedIn {
                    guard let freshAccessToken = try? await authentication.accessToken() else { return }
                    let snapshotRequired = await store.runGraphEventsOnce(
                        graphID: graphID,
                        baseURL: baseURL,
                        accessToken: freshAccessToken
                    )
                    guard store.syncError == nil else { return }
                    let shouldRefreshSnapshot = LogseqGraphSnapshotRefreshPolicy.shouldRefresh(
                        snapshotRequired: snapshotRequired,
                        isEditingOutlinerBlock: store.snapshot.outlinerState.editing != nil
                    )
                    if snapshotRequired && !shouldRefreshSnapshot {
                        store.deferSnapshotRefreshWhileEditing()
                    } else if shouldRefreshSnapshot {
                        guard let refreshedToken = try? await authentication.accessToken() else { return }
                        guard await store.bootstrapSelectedGraph(
                            graphID: graphID,
                            baseURL: baseURL,
                            accessToken: refreshedToken,
                            forceSnapshot: true,
                            isEncrypted: isEncrypted
                        ) else { return }
                    }
                    if !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            }
        }
    }

    private func beginGraphAccess(_ graphID: String) {
        if store.snapshot.isGraphEncrypted == true && store.snapshot.isGraphUnlocked != true {
            graphPassword = ""
            graphPasswordPresented = true
            return
        }
        startGraphSync(graphID)
    }

    private func unlockSelectedGraph() {
        let graphID = store.snapshot.selectedGraphId ?? selectedGraphID
        guard !graphID.isEmpty else { return }
        graphUnlockInProgress = true
        Task {
            await store.unlockGraph(graphPassword)
            graphUnlockInProgress = false
            guard store.lastError == nil else { return }
            graphPassword = ""
            graphPasswordPresented = false
            startGraphSync(graphID)
        }
    }

    private var appBackground: some View {
        platformAppBackground
            .ignoresSafeArea()
    }

    private var presentedError: LogseqChatCoreError? {
        guard let error = store.lastError,
              AppErrorPresentationPolicy.shouldPresent(code: error.code) else {
            return nil
        }
        return error
    }

    private var platformAppBackground: Color {
        themePalette.background
    }

    private var header: some View {
        VStack(spacing: 0) {
            topBar
        }
        .platformFloatingHeaderInset()
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            headerLeadingControl
                .buttonStyle(.plain)
            headerTitle
            Spacer()
            connectionControls
        }
        .padding(.horizontal, 20)
        .padding(.top, 0)
        .padding(.bottom, SidebarChromeMetrics.headerBottomPadding)
    }

    private var headerLeadingControl: some View {
        Button {
            if zoomedOutlinerBlock != nil {
                #if SKIP
                store.outlinerEvent(LogseqOutlinerEvent(type: "zoomOut"))
                #else
                let path = OutlinerNavigationPolicy.pathAfterBackButton(
                    appNavigationPath
                )
                if path == appNavigationPath {
                    store.outlinerEvent(LogseqOutlinerEvent(type: "zoomOut"))
                } else {
                    appNavigationPath = path
                }
                #endif
            } else if isNodePagePresented {
                #if SKIP
                store.closeNode()
                #endif
            } else if sidebarActivationAvailable {
                sidebarMotion.setSidebarPresented(!sidebarMotion.isPresented)
            }
        } label: {
            if zoomedOutlinerBlock != nil || isNodePagePresented {
                OutlinerBackIcon()
                    .stroke(style: StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round))
                    .frame(width: 10, height: 18)
            } else {
                SidebarMenuIcon()
            }
        }
        .frame(
            width: SidebarChromeMetrics.minimumHitTarget,
            height: SidebarChromeMetrics.minimumHitTarget
        )
        .foregroundStyle(.primary)
        .disabled(zoomedOutlinerBlock == nil && !isNodePagePresented && !sidebarActivationAvailable)
        .accessibilityLabel(
            zoomedOutlinerBlock == nil && !isNodePagePresented ? "Open sidebar" : "Back"
        )
        .accessibilityIdentifier(
            zoomedOutlinerBlock == nil && !isNodePagePresented
                ? "button.sidebar" : "button.outliner.zoom-out"
        )
    }

    private var headerTitle: some View {
        Text(verbatim: flashcardsPresented
            ? "Flashcards"
            : AppHeaderPolicy.title(
                zoomedBlockTitle: zoomedOutlinerBlock?.title,
                selectedPageTitle: activeNodeProjection?.page.title
                    ?? store.snapshot.selectedPage?.title
            ))
        .font(.subheadline)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var hasUnconfirmedSyncChanges: Bool {
        SyncIndicatorPolicy.hasUnconfirmedChanges(
            hasPendingSemanticOperations: store.snapshot.hasPendingSemanticOperations,
            hasPendingTransportRequest: store.snapshot.pendingSyncRequest != nil,
            cachedBlockStatuses: store.snapshot.blocks.map(\.syncStatus)
        )
    }

    private var hasFailedSyncChanges: Bool {
        store.snapshot.blocks.contains(where: \.isFailedSync)
    }

    private var syncStatusGraphName: String {
        if let graphName = store.snapshot.graphName, !graphName.isEmpty {
            return graphName
        }
        let graphID = store.snapshot.selectedGraphId ?? selectedGraphID
        return store.snapshot.graphs?.first(where: { $0.id == graphID })?.name
            ?? graphID
    }

    private var syncStatusSummary: String {
        SyncStatusDetailPolicy.summary(
            isConnected: syncConnectionAvailable,
            hasPendingChanges: hasUnconfirmedSyncChanges,
            hasFailedChanges: hasFailedSyncChanges
        )
    }

    private var syncIndicatorColor: Color {
        switch syncIndicatorState {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        }
    }

    private var syncIndicatorLabel: String {
        switch syncIndicatorState {
        case .green: return "Synced"
        case .yellow: return "Syncing"
        case .red:
            return hasFailedSyncChanges || store.syncError != nil ? "Sync failed" : "Not connected"
        }
    }

    private var syncIndicatorState: SyncIndicatorPolicy.State {
        SyncIndicatorPolicy.state(
            isConnected: syncConnectionAvailable,
            hasPendingChanges: hasUnconfirmedSyncChanges,
            hasFailedChanges: hasFailedSyncChanges,
            hasSyncError: store.syncError != nil
        )
    }

    private var syncConnectionAvailable: Bool {
        SyncConnectionPolicy.isAvailable(
            isConnected: store.snapshot.syncConnected == true,
            snapshotRefreshDeferred: store.isSnapshotRefreshDeferred
        )
    }

    private var syncIndicatorAccessibilityIdentifier: String {
        if syncIndicatorState == .red {
            return hasFailedSyncChanges || store.syncError != nil ? "sync.failed" : "sync.disconnected"
        }
        if store.cursorAdvancedAfterMutation {
            return "sync.cursor-advanced"
        }
        return syncConnectionAvailable ? "sync.connected" : "sync.disconnected"
    }

    @ViewBuilder private var connectionControls: some View {
        #if !SKIP
        if #available(iOS 26.0, macOS 26.0, *) {
            ControlGroup {
                syncIndicatorControl
                settingsControl
            }
            .controlGroupStyle(.navigation)
        } else {
            HStack(spacing: 0) {
                syncIndicatorControl
                settingsControl
            }
            .background(.ultraThinMaterial, in: Capsule())
        }
        #else
        HStack(spacing: 0) {
            syncIndicatorControl
            settingsControl
        }
        #endif
    }

    private var syncIndicatorControl: some View {
        Button {
            syncStatusPresented = true
        } label: {
            Circle()
                .fill(syncIndicatorColor)
                .frame(width: 10, height: 10)
        }
        .frame(width: 44, height: 44)
        .foregroundStyle(.primary)
        .accessibilityLabel(syncIndicatorLabel)
        .accessibilityIdentifier(syncIndicatorAccessibilityIdentifier)
    }

    private var settingsControl: some View {
        Menu {
            if let target = favoriteTargetPage {
                Button(favoriteTargetIsFavorite ? "Unfavorite" : "Favorite") {
                    store.setPageFavorite(
                        pageUUID: target.uuid,
                        favorite: !favoriteTargetIsFavorite
                    )
                }
                .accessibilityIdentifier("button.page-favorite")
                #if !SKIP && os(iOS)
                Button("Share") {
                    nodeSharePayload = NodeSharePayload(
                        pageTitle: target.title,
                        blocks: nodeShareBlocks
                    )
                }
                .accessibilityIdentifier("button.page-share")
                #elseif SKIP
                Button("Share") {
                    AndroidAssetImporter.share(
                        text: nodeShareText(target),
                        paths: NodeSharePolicy.localAssetPaths(blocks: nodeShareBlocks)
                    )
                }
                .accessibilityIdentifier("button.page-share")
                #else
                ShareLink(item: nodeShareText(target)) {
                    Text("Share")
                }
                .accessibilityIdentifier("button.page-share")
                #endif
                Button("Delete", role: .destructive) {
                    pagePendingDeletion = target
                }
                .accessibilityIdentifier("button.page-delete")
            } else {
                Button("Settings") {
                    settingsPresented = true
                }
            }
        } label: {
            Image(systemName: HeaderControlPolicy.settingsSystemImage)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .frame(width: 44, height: 44)
        .foregroundStyle(.primary)
        .accessibilityLabel("More")
        .accessibilityIdentifier("button.connection")
    }

    private var blockList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Color.clear
                        .frame(height: blockListContentTopPadding)
                        .id(Self.blockListTopID)
                    if let error = presentedError {
                        ErrorBanner(error: error)
                    }
                    if store.sections.isEmpty, !isLoadingGraph {
                        EmptyBlocksView()
                    } else {
                        ForEach(store.sections(for: LogseqContentMode.chat)) { section in
                            Text(verbatim: section.title)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.top, 8)
                            ForEach(section.blocks) { block in
                                if block.isAsset {
                                    BlockRow(
                                        block: block,
                                        onOpenAsset: { openAsset(block) },
                                        onDelete: { confirmDelete(block) }
                                    )
                                } else {
                                    BlockRow(
                                        block: block,
                                        statuses: availableTaskStatuses,
                                        onEdit: { handleBlockTap(block) },
                                        onOpenMarkupLink: openMarkupLink,
                                        onStatusChange: { status in
                                            store.updateStatus(block: block, status: status)
                                        },
                                        onDelete: { confirmDelete(block) }
                                    )
                                }
                            }
                        }
                    }
                    Color.clear
                        .frame(height: blockListContentBottomPadding)
                        .id(Self.blockListBottomID)
                }
                .padding(.horizontal, 12)
            }
            .onAppear {
                autoScrollOnFirstAppear(proxy)
            }
            .onChange(of: store.snapshot.blocks) { oldBlocks, newBlocks in
                if !hasAutoScrolledInitially {
                    autoScrollOnFirstAppear(proxy)
                } else if BlockListUpdatePolicy.shouldScrollToBottom(
                    oldBlockIDs: Set(oldBlocks.map(\.uuid)),
                    newBlockIDs: Set(newBlocks.map(\.uuid))
                ) {
                    scrollToBottom(proxy)
                }
            }
        }
    }

    private func confirmDelete(_ block: LogseqBlock) {
        blocksPendingDeletion = [block]
    }

    private var blockListContentTopPadding: CGFloat {
        #if SKIP
        return 60.0
        #else
        return 16.0
        #endif
    }

    private var blockListContentBottomPadding: CGFloat {
        #if !SKIP && os(iOS)
        MobileChromePolicy.minimumScrollableBottomClearance
        #else
        72.0
        #endif
    }

    private func handleBlockTap(_ block: LogseqBlock) {
        guard !composerExpanded else {
            dismissComposerEditing()
            return
        }
        editBlock(block)
    }

    private func finishOutlinerEditing(_ block: LogseqBlock? = nil) {
        guard outlinerEditing != nil else { return }
        store.outlinerEvent(LogseqOutlinerEvent(type: "cancelEditing"))
    }

    private func performOutlinerPlatformCommands() {
        for command in store.snapshot.outlinerCommands {
            switch command.type {
            case "haptic":
                #if !SKIP && os(iOS)
                if command.style == "selection" {
                    UISelectionFeedbackGenerator().selectionChanged()
                } else {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                #endif
            case "confirmDelete":
                let ids = Set(command.uuids ?? [])
                let blocks = activeNodeProjection?.blocks ?? store.snapshot.blocks
                blocksPendingDeletion = blocks.filter { ids.contains($0.uuid) }
                outlinerDeleteConfirmationPending = !blocksPendingDeletion.isEmpty
            case "setClipboardText":
                #if !SKIP && os(iOS)
                UIPasteboard.general.string = command.text
                #endif
            case "setClipboardReferences":
                #if !SKIP && os(iOS)
                UIPasteboard.general.string = OutlinerClipboardPolicy.nodeReferences(
                    command.uuids ?? []
                )
                #endif
            case "setClipboardURLs":
                #if !SKIP && os(iOS)
                UIPasteboard.general.string = (command.uuids ?? []).map {
                    "logseq://graph/\(graphSubtitle)?block-id=\($0)"
                }.joined(separator: "\n")
                #endif
            case "pickAttachment":
                pendingAssetTargetBlockID = command.uuid
                fileImporterPresented = true
            case "takePhoto":
                #if !SKIP && os(iOS)
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    pendingAssetTargetBlockID = command.uuid
                    cameraPresented = true
                }
                #endif
            case "recordAudio":
                #if SKIP
                androidAudioRecorderTargetBlockID = command.uuid
                androidAudioRecorderPresented = true
                #else
                #if !SKIP && os(iOS)
                audioRecorderTargetBlockID = command.uuid
                audioRecorderPresented = true
                #endif
                #endif
            case "focusBlock":
                break
            default:
                break
            }
        }
    }

    private func editBlock(_ block: LogseqBlock) {
        editingBlock = block
        draft = block.title
        selectedTaskStatus = block.status
        composerExpanded = true
        focusComposer()
    }

    private func openAsset(_ block: LogseqBlock) {
        dismissComposerEditing()
        #if !SKIP && os(iOS)
        guard let url = LocalAssetPath.resolve(
            block.localPath,
            title: block.title,
            assetType: block.assetType
        ) else { return }
        previewAssetURL = url
        #elseif SKIP
        guard let path = block.localPath, !path.isEmpty else { return }
        AndroidAssetImporter.openFile(path: path, contentType: block.assetType ?? "application/octet-stream")
        #endif
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard !store.snapshot.blocks.isEmpty else { return }
        proxy.scrollTo(Self.blockListBottomID, anchor: .bottom)
    }

    private func autoScrollOnFirstAppear(_ proxy: ScrollViewProxy) {
        guard !hasAutoScrolledInitially else { return }
        guard !store.snapshot.blocks.isEmpty else { return }
        hasAutoScrolledInitially = true
        scrollToBottom(proxy)
    }

    #if SKIP
    private var androidFloatingControls: some View {
        Group {
            if shouldShowExpandedComposer {
                floatingComposer
            } else if shouldShowComposer && !composerExpanded {
                HStack(spacing: 10) {
                    collapsedComposer
                    Button {
                        expandSearch()
                    } label: {
                        IconImage(name: "search")
                            .frame(width: 24, height: 24)
                            .frame(width: 58, height: 58)
                    }
                    .buttonStyle(.plain)
                    .platformGlassContainer()
                    .platformRoundedHitTarget(cornerRadius: 30)
                    .accessibilityLabel("Search")
                    .accessibilityIdentifier("button.search")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
    }
    #endif

    #if !SKIP && os(iOS)
    @ViewBuilder private var iosBottomChrome: some View {
        Group {
            switch bottomChromePresentation {
            case .outlinerSelection:
                OutlinerSelectionToolbar(onAction: handleOutlinerSelectionToolbarAction)
                    .platformGlassContainer()
                    .padding(.horizontal, 16)
                    .padding(.bottom, MobileChromePolicy.bottomControlScreenEdgeInset)
            case .outlinerEditor:
                VStack(spacing: 0) {
                    if !outlinerAutocompleteCandidates.isEmpty {
                        OutlinerAutocompleteBar(
                            candidates: outlinerAutocompleteCandidates,
                            onSelect: completeOutlinerAutocomplete
                        )
                    }
                    OutlinerEditorToolbar(onAction: handleOutlinerEditorToolbarAction)
                }
                    .platformGlassContainer()
                    .padding(.horizontal, 16)
                    .padding(.bottom, MobileChromePolicy.editorBottomScreenEdgeInset)
            case .expandedComposer:
                composer
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, MobileChromePolicy.bottomControlScreenEdgeInset)
            case .captureAndSearch:
                HStack(spacing: 10) {
                    collapsedComposer
                    Button(action: presentSearch) {
                        IconImage(name: "search")
                            .frame(width: 24, height: 24)
                            .frame(width: 58, height: 58)
                    }
                    .buttonStyle(.plain)
                    .platformGlassContainer()
                    .platformRoundedHitTarget(cornerRadius: 30)
                    .accessibilityLabel("Search")
                    .accessibilityIdentifier("button.search")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, MobileChromePolicy.bottomControlScreenEdgeInset)
            case .hidden:
                EmptyView()
            }
        }
    }

    private func handleOutlinerEditorToolbarAction(_ action: OutlinerToolbarAction) {
        guard let eventValue = action.eventValue else { return }
        store.outlinerEvent(LogseqOutlinerEvent(type: "toolbar", action: eventValue))
    }

    private func handleOutlinerSelectionToolbarAction(_ action: OutlinerToolbarAction) {
        guard let eventValue = action.eventValue else { return }
        store.outlinerEvent(LogseqOutlinerEvent(type: "toolbar", action: eventValue))
    }

    private var outlinerAutocompleteCandidates: [LogseqOutlinerAutocompleteCandidate] {
        activeNodeProjection?.outlinerAutocompleteCandidates
            ?? store.snapshot.outlinerAutocompleteCandidates
    }

    private func completeOutlinerAutocomplete(_ candidate: LogseqOutlinerAutocompleteCandidate) {
        store.outlinerEvent(LogseqOutlinerEvent(
            type: "chooseAutocomplete",
            value: candidate.value
        ))
    }
    #endif

    private var floatingComposer: some View {
        composer
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
    }

    private var composer: some View {
        Group {
            if composerExpanded {
                expandedComposer
            } else {
                collapsedComposer
            }
        }
    }

    private var expandedComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Capture", text: $draft, axis: .vertical)
                .platformComposerLineLimit()
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 36, alignment: .topLeading)
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .accessibilityIdentifier("field.composer")
            HStack(alignment: .center, spacing: 8) {
                Menu {
                    #if SKIP
                    Button {
                        AndroidAssetImporter.pickPhotos { title, assetType, size, checksum, path in
                            store.addAsset(
                                title: title,
                                assetType: assetType,
                                assetSize: size,
                                assetChecksum: checksum,
                                localPath: path
                            )
                        }
                    } label: {
                        HStack {
                            IconImage(name: "photo")
                            Text("Photo")
                        }
                    }
                    Button {
                        AndroidAssetImporter.takePhoto { title, assetType, size, checksum, path in
                            store.addAsset(
                                title: title,
                                assetType: assetType,
                                assetSize: size,
                                assetChecksum: checksum,
                                localPath: path
                            )
                        }
                    } label: {
                        HStack {
                            IconImage(name: "camera")
                            Text("Camera")
                        }
                    }
                    Button {
                        AndroidAssetImporter.pickFiles { title, assetType, size, checksum, path in
                            store.addAsset(
                                title: title,
                                assetType: assetType,
                                assetSize: size,
                                assetChecksum: checksum,
                                localPath: path
                            )
                        }
                    } label: {
                        HStack {
                            IconImage(name: "paperclip")
                            Text("File")
                        }
                    }
                    Button {
                        androidAudioRecorderTargetBlockID = nil
                        androidAudioRecorderPresented = true
                    } label: {
                        HStack {
                            IconImage(name: "audio")
                            Text("Audio recording")
                        }
                    }
                    #else
                    // Bottom-anchored iOS menus place the first action nearest the trigger.
                    Button {
                        pendingAssetTargetBlockID = nil
                        fileImporterPresented = true
                    } label: {
                        HStack {
                            Image(systemName: "paperclip")
                            Text("File")
                        }
                    }
                    #if os(iOS)
                    Button {
                        pendingAssetTargetBlockID = nil
                        cameraPresented = true
                    } label: {
                        HStack {
                            Image(systemName: "camera")
                            Text("Camera")
                        }
                    }
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    #endif
                    Button {
                        pendingAssetTargetBlockID = nil
                        photoPickerPresented = true
                    } label: {
                        HStack {
                            Image(systemName: "photo.on.rectangle.angled")
                            Text("Photo")
                        }
                    }
                    #if os(iOS)
                    Button {
                        audioRecorderTargetBlockID = nil
                        audioRecorderPresented = true
                    } label: {
                        HStack {
                            Image(systemName: "mic")
                            Text("Audio recording")
                        }
                    }
                    #endif
                    #endif
                } label: {
                    IconImage(name: "plus", size: 24)
                        .frame(width: 32, height: 32)
                        .foregroundStyle(Color.primary)
                }
                .accessibilityLabel("Add attachment")
                .accessibilityIdentifier("button.attachment")
                .tint(Color.primary)
                .platformIconMenuStyle()
                composerTaskStatusControl
                Spacer()
                Button {
                    sendDraft()
                } label: {
                    IconImage(name: "arrow_upward")
                        .frame(width: 18, height: 18)
                        .frame(width: 40, height: 40)
                        .foregroundStyle(Color.white)
                        .background(Circle().fill(Color.black))
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("button.send")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .platformGlassContainer(cornerRadius: 10)
        .platformRoundedHitTarget(cornerRadius: 10)
        .onTapGesture {
            focusComposer()
        }
        .onChange(of: draft) { _, value in
            persistedDraft = value
            if composerExpanded && value.isEmpty {
                focusComposer()
            }
        }
    }

    @ViewBuilder private var composerTaskStatusControl: some View {
        #if SKIP
        Menu {
            ForEach(taskStatusMenuStatuses) { status in
                taskStatusButton(status)
            }
            if selectedTaskStatus != nil {
                Button("Clear task status") { selectedTaskStatus = nil }
            }
        } label: {
            composerTaskStatusLabel
        }
        .platformIconMenuStyle()
        #else
        Button {
            taskStatusPickerPresented = true
        } label: {
            composerTaskStatusLabel
        }
        .buttonStyle(.plain)
        .popover(isPresented: $taskStatusPickerPresented, arrowEdge: .bottom) {
            composerTaskStatusChoices
                .presentationCompactAdaptation(.popover)
        }
        #endif
    }

    private var composerTaskStatusLabel: some View {
        TaskStatusIcon(
            status: selectedTaskStatus ?? LogseqTaskStatus.todo,
            size: 24
        )
        .opacity(selectedTaskStatus == nil ? 0.55 : 1.0)
        .frame(width: 32, height: 32)
        .accessibilityLabel("Task status")
        .accessibilityIdentifier("button.task-status")
    }

    #if !SKIP
    private var composerTaskStatusChoices: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(taskStatusMenuStatuses) { status in
                Button {
                    selectedTaskStatus = status
                    taskStatusPickerPresented = false
                } label: {
                    HStack(spacing: 12) {
                        TaskStatusIcon(status: status, size: 24)
                        Text(verbatim: status.title)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 16)
                    }
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if selectedTaskStatus != nil {
                Divider()
                Button("Clear task status") {
                    selectedTaskStatus = nil
                    taskStatusPickerPresented = false
                }
                .buttonStyle(.plain)
                .frame(minHeight: 40, alignment: .leading)
            }
        }
        .padding(12)
        .frame(minWidth: 220)
    }
    #endif

    private var collapsedComposer: some View {
        Button {
            expandComposer()
        } label: {
            Text(verbatim: "Capture")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                .padding(.horizontal, 30)
                .platformRectangularHitTarget()
        }
        .buttonStyle(.plain)
        .platformGlassContainer()
        .platformRoundedHitTarget(cornerRadius: 30)
        .accessibilityIdentifier("button.composer.expand")
    }

    private func expandComposer() {
        #if SKIP
        composerExpanded = true
        #else
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            composerExpanded = true
        }
        #endif
        focusComposer()
    }

    private func focusComposer() {
        #if SKIP
        DispatchQueue.main.async {
            composerFocused = true
        }
        #else
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            composerFocused = true
        }
        #endif
    }

    #if !SKIP
    private func presentSearch() {
        composerExpanded = false
        searchPagePresented = true
    }
    #endif

    private func expandSearch() {
        composerExpanded = false
        searchPagePresented = true
    }

    private func dismissComposerEditing() {
        composerExpanded = false
        composerFocused = false
        draft = ""
        persistedDraft = ""
        selectedTaskStatus = nil
        editingBlock = nil
    }

    private func sendDraft() {
        let submittedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submittedDraft.isEmpty else { return }
        let editingBlock = editingBlock
        let selectedTaskStatus = selectedTaskStatus
        draft = ""
        persistedDraft = ""
        if let editingBlock {
            store.update(block: editingBlock, title: submittedDraft, status: selectedTaskStatus)
            self.editingBlock = nil
            self.selectedTaskStatus = nil
        } else if let selectedTaskStatus {
            store.sendTask(submittedDraft, status: selectedTaskStatus)
        } else {
            store.send(submittedDraft)
        }
        composerExpanded = true
        focusComposer()
    }

    @ViewBuilder private func taskStatusButton(_ status: LogseqTaskStatus) -> some View {
        Button {
            selectedTaskStatus = status
        } label: {
            HStack {
                TaskStatusIcon(status: status)
                Text(verbatim: status.title)
            }
        }
    }

    private var availableTaskStatuses: [LogseqTaskStatus] {
        LogseqTaskStatus.availableChoices(catalog: store.snapshot.taskStatuses ?? [])
    }

    private var taskStatusMenuStatuses: [LogseqTaskStatus] {
        return availableTaskStatuses
    }

    #if !SKIP
    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        selectedPhotoItems = []
        Task {
            for item in items {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                    let fileExtension = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                    let metadata = try await Self.persistImportedData(
                        data,
                        title: "Photo-\(UUID().uuidString).\(fileExtension)"
                    )
                    addImportedAsset(metadata)
                } catch {
                    logger.error("Photo import failed: \(String(describing: error))")
                }
            }
        }
    }

    #if os(iOS)
    private func importCapturedPhoto(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            logger.error("Camera import failed: JPEG encoding returned no data")
            return
        }
        Task {
            do {
                let metadata = try await Self.persistImportedData(
                    data,
                    title: "Camera-\(UUID().uuidString).jpg"
                )
                addImportedAsset(metadata)
            } catch {
                logger.error("Camera import failed: \(String(describing: error))")
            }
        }
    }
    #endif

    private func addImportedAsset(_ metadata: ImportedAsset) {
        store.addAsset(
            title: metadata.title,
            assetType: metadata.assetType,
            assetSize: metadata.size,
            assetChecksum: metadata.checksum,
            localPath: LocalAssetPath.storedPath(metadata.path),
            targetBlockId: pendingAssetTargetBlockID
        )
    }

    private func importAssets(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        Task {
            for url in urls {
                do {
                    let metadata = try await Self.persistImportedAsset(url)
                    addImportedAsset(metadata)
                } catch {
                    logger.error("Asset import failed: \(String(describing: error))")
                }
            }
        }
    }

    private nonisolated static func persistImportedAsset(_ sourceURL: URL) async throws -> ImportedAsset {
        try await Task.detached(priority: .utility) {
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Assets", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(UUID().uuidString + "-" + sourceURL.lastPathComponent)
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let handle = try FileHandle(forReadingFrom: destination)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                hash.update(data: chunk)
            }
            let checksum = hash.finalize().map { String(format: "%02x", $0) }.joined()
            return ImportedAsset(
                title: sourceURL.lastPathComponent,
                assetType: destination.pathExtension.lowercased(),
                size: size,
                checksum: checksum,
                path: destination.path
            )
        }.value
    }

    private nonisolated static func persistImportedData(_ data: Data, title: String) async throws -> ImportedAsset {
        try await Task.detached(priority: .utility) {
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Assets", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(title)
            try data.write(to: destination, options: .atomic)
            let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return ImportedAsset(
                title: title,
                assetType: destination.pathExtension.lowercased(),
                size: data.count,
                checksum: checksum,
                path: destination.path
            )
        }.value
    }
    #endif
}

#if !SKIP
private struct ImportedAsset: Sendable {
    let title: String
    let assetType: String
    let size: Int
    let checksum: String
    let path: String
}
#endif

private struct ConnectionSettingsView: View {
    @Binding var baseURL: String
    let graphDatabasePath: String?
    let apply: () -> Void
    let signOut: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("logseq.appearance") private var appearance = "system"
    @AppStorage("logseq.language") private var language = "system"
    @AppStorage("logseq.editor.spellCheck") private var spellCheck = true
    @AppStorage("logseq.editor.autoCorrection") private var autoCorrection = true
    @State private var logPresented = false

    private var palette: LogseqThemePalette {
        LogseqThemePolicy.palette(
            mode: LogseqThemeMode(rawValue: appearance) ?? .system,
            systemIsDark: colorScheme == .dark
        )
    }

    private var normalizedBaseURL: String? {
        LogseqSettingsPolicy.normalizedSyncServerURL(baseURL)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    settingsSection(Text("General")) {
                        HStack {
                            Text("Theme")
                            Spacer()
                            Picker("Theme", selection: $appearance) {
                                Text("System").tag("system")
                                Text("Light").tag("light")
                                Text("Dark").tag("dark")
                            }
                            .labelsHidden()
                        }
                        Divider()
                        HStack {
                            Text("Language")
                            Spacer()
                            Picker("Language", selection: $language) {
                                ForEach(LogseqSettingsPolicy.languages) { choice in
                                    languageLabel(choice).tag(choice.id)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    settingsSection(Text("Editor")) {
                        Toggle("Spell check", isOn: $spellCheck)
                        Divider()
                        Toggle("Auto-correction", isOn: $autoCorrection)
                    }
                    settingsSection(Text("Sync server")) {
                        TextField("Server URL", text: $baseURL)
                            .accessibilityIdentifier("field.base-url")
                        if !baseURL.isEmpty, normalizedBaseURL == nil {
                            Text("Enter a valid HTTP or HTTPS URL.")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    #if !SKIP
                    if let graphDatabasePath {
                        let graphDatabaseURL = URL(fileURLWithPath: graphDatabasePath)
                        settingsSection(Text("Advanced")) {
                            ShareLink(item: graphDatabaseURL) {
                                Text("Export Graph SQLite DB")
                            }
                            .accessibilityIdentifier("button.export-graph-database")
                        }
                    }
                    #endif
                    settingsSection(Text("About")) {
                        settingsValueRow(Text("Version"), value: LogseqSettingsPolicy.version)
                        Divider()
                        settingsValueRow(Text("Revision"), value: LogseqSettingsPolicy.revision)
                        Divider()
                        Button("Check log") {
                            logPresented = true
                        }
                    }
                    settingsSection(Text("Community")) {
                        ForEach(LogseqSettingsPolicy.communityLinks) { destination in
                            Link(destination: destination.url) {
                                communityLabel(destination.title)
                            }
                            if destination.id != LogseqSettingsPolicy.communityLinks.last?.id {
                                Divider()
                            }
                        }
                    }
                    settingsSection(nil) {
                        Button("Sign Out", role: .destructive) {
                            signOut()
                        }
                        .accessibilityIdentifier("button.sign-out")
                    }
                }
                .padding(20)
            }
            .background(palette.background.ignoresSafeArea())
            .foregroundStyle(palette.primaryText)
            .tint(LogseqThemePolicy.accent)
            .accessibilityIdentifier("screen.settings")
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier("button.connection.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        guard let normalizedBaseURL else { return }
                        baseURL = normalizedBaseURL
                        apply()
                    }
                    .disabled(normalizedBaseURL == nil)
                    .accessibilityIdentifier("button.connection.apply")
                }
            }
            .sheet(isPresented: $logPresented) {
                RuntimeLogView(palette: palette) {
                    logPresented = false
                }
            }
        }
    }

    @ViewBuilder private func settingsSection<Content: View>(
        _ title: Text?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                title
                    .font(.headline)
                    .foregroundStyle(palette.secondaryText)
            }
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func settingsValueRow(_ title: Text, value: String) -> some View {
        HStack {
            title
            Spacer()
            Text(value)
                .foregroundStyle(palette.secondaryText)
        }
    }

    private func languageLabel(_ choice: LogseqLanguageChoice) -> Text {
        choice.id == "system" ? Text("System") : Text(verbatim: choice.title)
    }

    private func communityLabel(_ title: String) -> Text {
        switch title {
        case "Report bug":
            return Text("Report bug")
        case "Discord community":
            return Text("Discord community")
        case "Forum":
            return Text("Forum")
        case "GitHub":
            return Text("GitHub")
        default:
            return Text(verbatim: title)
        }
    }
}

private struct RuntimeLogView: View {
    let palette: LogseqThemePalette
    let dismiss: () -> Void
    @State private var source = LogseqRuntimeLogSource.ui
    @State private var errorsOnly = false
    @State private var newestFirst = false
    @State private var refreshRevision = 0

    private var records: [LogseqRuntimeLogRecord] {
        _ = refreshRevision
        return LogseqRuntimeLog.shared.records(
            source: source,
            errorsOnly: errorsOnly,
            newestFirst: newestFirst
        )
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        Button(errorsOnly ? "All" : "Errors only") {
                            errorsOnly.toggle()
                        }
                        .accessibilityIdentifier("button.log-errors")
                        Button(newestFirst ? "Oldest first" : "Newest first") {
                            newestFirst.toggle()
                        }
                        .accessibilityIdentifier("button.log-order")
                        Button(source == .ui ? "Core log" : "UI log") {
                            source = source == .ui ? .core : .ui
                        }
                        .accessibilityIdentifier("button.log-source")
                        Button("Copy") {
                            copy(records.map(runtimeLogLine).joined(separator: "\n"))
                        }
                        .accessibilityIdentifier("button.log-copy")
                    }
                    .buttonStyle(.bordered)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if records.isEmpty {
                            Text("No log entries")
                                .foregroundStyle(palette.secondaryText)
                        } else {
                            ForEach(records) { record in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(verbatim: record.level.rawValue.uppercased())
                                            .fontWeight(.semibold)
                                            .foregroundStyle(record.level == .error ? .red : palette.secondaryText)
                                        Text(
                                            Date(timeIntervalSince1970: Double(record.timestampMilliseconds) / 1_000),
                                            style: .time
                                        )
                                        .foregroundStyle(palette.secondaryText)
                                    }
                                    Text(verbatim: record.message)
                                }
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(16)
            .background(palette.background.ignoresSafeArea())
            .foregroundStyle(palette.primaryText)
            .navigationTitle("Log")
            .accessibilityIdentifier("screen.runtime-log")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Refresh") { refreshRevision += 1 }
                        .accessibilityIdentifier("button.log-refresh")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss)
                }
            }
        }
    }

    private func runtimeLogLine(_ record: LogseqRuntimeLogRecord) -> String {
        "\(record.timestampMilliseconds) \(record.level.rawValue.uppercased()) \(record.source.rawValue) \(record.message)"
    }

    private func copy(_ text: String) {
        #if SKIP
        AndroidAssetImporter.copyText(text: text)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

extension View {
    @ViewBuilder public func platformSidebarSafeAreaPadding(
        top: CGFloat,
        bottom: CGFloat
    ) -> some View {
        #if !SKIP && os(iOS)
        self.safeAreaPadding(.top, top)
            .safeAreaPadding(.bottom, bottom)
        #else
        self
        #endif
    }

    @ViewBuilder public func platformFullScreenSidebarShell() -> some View {
        #if !SKIP && os(iOS)
        self.ignoresSafeArea(.container)
        #else
        self
        #endif
    }

    @ViewBuilder public func platformGlassButtonStyle() -> some View {
        #if !SKIP
        if #available(iOS 26.0, macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
        #else
        self.buttonStyle(.bordered)
        #endif
    }

    @ViewBuilder public func platformGlassProminentButtonStyle() -> some View {
        #if !SKIP
        if #available(iOS 26.0, macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
        #else
        self.buttonStyle(.borderedProminent)
        #endif
    }

    @ViewBuilder public func platformCircleButtonShape() -> some View {
        #if !SKIP
        self.buttonBorderShape(.circle)
        #else
        self
        #endif
    }

    @ViewBuilder public func platformSmallControl() -> some View {
        #if !SKIP
        self.controlSize(.small)
        #else
        self
        #endif
    }

    @ViewBuilder public func platformIconMenuStyle() -> some View {
        #if os(macOS) && !SKIP
        self.menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        #else
        self
        #endif
    }

    @ViewBuilder public func platformRectangularHitTarget() -> some View {
        #if !SKIP
        self.contentShape(Rectangle())
        #else
        self
        #endif
    }

    @ViewBuilder public func platformRoundedHitTarget(cornerRadius: CGFloat) -> some View {
        #if !SKIP
        self.contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        #else
        self
        #endif
    }

    @ViewBuilder public func platformComposerLineLimit() -> some View {
        #if !SKIP
        self.lineLimit(1...6)
        #else
        self.lineLimit(6)
        #endif
    }

    #if !SKIP
    @ViewBuilder public func platformRootNavigationChromeHidden() -> some View {
        #if os(iOS)
        if #available(iOS 18.0, *) {
            self.toolbarVisibility(.hidden, for: .navigationBar)
        } else {
            self.toolbar(.hidden, for: .navigationBar)
        }
        #else
        self
        #endif
    }

    #endif

    @ViewBuilder public func platformGlassContainer(cornerRadius: CGFloat = 28) -> some View {
        #if !SKIP
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        #else
        self.background(Color.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        #endif
    }

    @ViewBuilder public func platformGlassCapsule() -> some View {
        #if !SKIP
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect()
        } else {
            self.background(.ultraThinMaterial)
        }
        #else
        self.background(Color.primary.opacity(0.08))
            .cornerRadius(26)
        #endif
    }

    @ViewBuilder public func platformLegacyHeaderChrome() -> some View {
        #if !SKIP
        self.background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea(edges: .top)
        }
            .overlay(alignment: .bottom) {
                Divider()
                    .opacity(0.2)
            }
        #else
        self
        #endif
    }

    @ViewBuilder public func platformContinuousHeaderChrome() -> some View {
        #if !SKIP && os(iOS)
        self.background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .frame(height: SidebarChromeMetrics.headerHeight + 200)
                .offset(y: -100)
        }
        #else
        self.platformLegacyHeaderChrome()
        #endif
    }

    @ViewBuilder public func platformFloatingHeaderInset() -> some View {
        #if !SKIP
        self.padding(.top, 0)
        #else
        self.padding(.top, 28)
        #endif
    }

    @ViewBuilder public func platformFloatingComposerInset() -> some View {
        #if !SKIP
        self.padding(.bottom, 6)
        #else
        self.padding(.bottom, 10)
        #endif
    }

}

private struct SyncStatusView: View {
    let graphName: String
    let summary: String
    let isConnected: Bool
    let hasPendingChanges: Bool
    let cursor: Int?
    let errorMessage: String?
    let syncNow: () -> Void
    let close: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    statusRow(label: "Status", value: summary)
                    statusRow(label: "Graph", value: graphName)
                    statusRow(
                        label: "Connection",
                        value: isConnected ? "Connected" : "Disconnected"
                    )
                    statusRow(
                        label: "Local changes",
                        value: hasPendingChanges ? "Waiting to save" : "Saved"
                    )
                    statusRow(
                        label: "Server cursor",
                        value: cursor.map { String($0) } ?? "Unavailable"
                    )
                }
                if let errorMessage, !errorMessage.isEmpty {
                    Section("Last error") {
                        Text(verbatim: errorMessage)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button("Sync now", action: syncNow)
                        .accessibilityIdentifier("button.sync-now")
                }
            }
            .navigationTitle("Sync status")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: close)
                }
            }
        }
    }

    private func statusRow(label: String, value: String) -> some View {
        HStack {
            Text(verbatim: label)
            Spacer()
            Text(verbatim: value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct BlockRow: View {
    let block: LogseqBlock
    var statuses: [LogseqTaskStatus] = []
    var onOpenAsset: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onOpenMarkupLink: ((OutlinerMarkupLink) -> Void)? = nil
    var onStatusChange: ((LogseqTaskStatus) -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if block.isAsset {
                AssetPreview(block: block, onOpen: onOpenAsset)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    if let status = block.status {
                        Menu {
                            ForEach(statuses) { option in
                                Button {
                                    onStatusChange?(option)
                                } label: {
                                    HStack {
                                        TaskStatusIcon(status: option)
                                        Text(verbatim: option.title)
                                    }
                                }
                                .accessibilityIdentifier(
                                    "button.block-task-status-option.\(option.ident ?? option.uuid)"
                                )
                            }
                        } label: {
                            TaskStatusIcon(status: status, size: 24)
                                .frame(width: 24, height: 24)
                        }
                        .accessibilityLabel("Task status")
                        .accessibilityIdentifier("button.block-task-status")
                        .platformIconMenuStyle()
                    }
                    renderedTitle
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .padding(.top, 2)
                }
            }
            BlockTrailingTags(
                tags: BlockTagPresentationPolicy.trailingTags(
                    tags: block.tags,
                    markup: block.markup
                ),
                onOpenTag: { onOpenMarkupLink?(.node(uuid: $0)) }
            )
            HStack(spacing: 6) {
                Text(verbatim: block.timeTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if block.isFailedSync {
                    ProgressView()
                        .platformSmallControl()
                        .frame(width: 14, height: 14)
                        .accessibilityLabel("Sync failed")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.06))
        .cornerRadius(18)
        .onTapGesture {
            onEdit?()
        }
        .contextMenu {
            Button("Delete", role: .destructive) {
                onDelete?()
            }
        }
    }

    @ViewBuilder private var renderedTitle: some View {
        #if !SKIP
        Text(OutlinerMarkupAttributedString.make(
            nodes: block.markup,
            fallback: block.title.isEmpty ? " " : block.title
        ))
        .environment(\.openURL, OpenURLAction { url in
            guard let link = OutlinerMarkupLink(url: url) else { return .systemAction }
            onOpenMarkupLink?(link)
            return .handled
        })
        #else
        Text(verbatim: block.title.isEmpty ? " " : block.title)
        #endif
    }
}

enum AssetPresentationKind: Equatable {
    case image
    case audio
    case file
}

enum AssetPresentationPolicy {
    static func kind(assetType: String?, localPath: String?) -> AssetPresentationKind {
        let pathExtension = localPath.map { URL(fileURLWithPath: $0).pathExtension }
        let normalizedType = (assetType ?? pathExtension ?? "").lowercased()
        if normalizedType.hasPrefix("image/")
            || ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains(normalizedType) {
            return .image
        }
        if normalizedType.hasPrefix("audio/")
            || ["m4a", "mp3", "wav", "aac", "caf"].contains(normalizedType) {
            return .audio
        }
        return .file
    }
}

struct AssetPreview: View {
    let block: LogseqBlock
    let onOpen: (() -> Void)?

    var body: some View {
        #if !SKIP && os(iOS)
        if let url = LocalAssetPath.resolve(
            block.localPath,
            title: block.title,
            assetType: block.assetType
        ),
           presentationKind == .image,
           let image = UIImage(contentsOfFile: url.path) {
            Button { onOpen?() } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("asset.preview.image")
        } else if let url = LocalAssetPath.resolve(
            block.localPath,
            title: block.title,
            assetType: block.assetType
        ),
                  presentationKind == .audio {
            VStack(alignment: .leading, spacing: 8) {
                assetTitle
                AssetAudioPlayer(path: url.path)
                    .frame(height: 44)
            }
        } else {
            fileButton
        }
        #else
        fileButton
        #endif
    }

    private var presentationKind: AssetPresentationKind {
        AssetPresentationPolicy.kind(assetType: block.assetType, localPath: block.localPath)
    }

    private var assetTitle: some View {
        Text(verbatim: block.title.isEmpty ? "Untitled file" : block.title)
            .font(.body)
            .fontWeight(.medium)
            .foregroundStyle(.primary)
            .lineLimit(3)
    }

    private var fileButton: some View {
        Button { openFile() } label: {
            HStack(spacing: 8) {
                IconImage(name: presentationKind == .audio ? "audio" : "paperclip")
                    .frame(width: 18, height: 18)
                assetTitle
            }
        }
        .buttonStyle(.plain)
    }

    private func openFile() {
        if let onOpen {
            onOpen()
            return
        }
        #if SKIP
        guard let path = block.localPath, !path.isEmpty else { return }
        AndroidAssetImporter.openFile(
            path: path,
            contentType: block.assetType ?? "application/octet-stream"
        )
        #endif
    }
}

#if !SKIP && os(iOS)
private struct AssetAudioPlayer: View {
    @State private var player: AVPlayer
    @State private var isPlaying = false

    init(path: String) {
        _player = State(initialValue: AVPlayer(url: URL(fileURLWithPath: path)))
    }

    var body: some View {
        Button {
            if isPlaying {
                player.pause()
            } else {
                player.play()
            }
            isPlaying.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 20, height: 20)
                Text(verbatim: isPlaying ? "Pause audio" : "Play audio")
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("player.asset.audio")
        .accessibilityLabel(isPlaying ? "Pause audio" : "Play audio")
        .onDisappear {
            player.pause()
            isPlaying = false
        }
    }
}
#endif

struct TaskStatusIcon: View {
    let status: LogseqTaskStatus
    let size: CGFloat

    init(status: LogseqTaskStatus, size: CGFloat = 16) {
        self.status = status
        self.size = size
    }

    private var statusStyle: String {
        let value = (status.ident ?? status.icon?.id ?? status.title).lowercased()
        if value.contains("backlog") { return "backlog" }
        if value.contains("in-review") || value.contains("inreview") { return "in-review" }
        if value.contains("doing") || value.contains("inprogress") || value.contains("progress") { return "doing" }
        if value.contains("done") || value.contains("circle-check") { return "done" }
        if value.contains("cancel") || value.contains("circle-x") { return "canceled" }
        return "todo"
    }

    private var color: Color {
        if let customColor = status.icon?.color, let color = taskStatusColor(hex: customColor) {
            return color
        }
        switch statusStyle {
        case "backlog": return Color(red: 0.66, green: 0.64, blue: 0.62)
        case "todo": return Color(red: 0.47, green: 0.44, blue: 0.42)
        case "doing": return Color(red: 0.79, green: 0.54, blue: 0.02)
        case "in-review": return Color(red: 0.11, green: 0.31, blue: 0.85)
        case "done": return Color(red: 0.09, green: 0.64, blue: 0.29)
        case "canceled": return Color(red: 0.86, green: 0.15, blue: 0.15)
        default: return .secondary
        }
    }

    private var iconName: String {
        switch statusStyle {
        case "backlog": return "task_backlog"
        case "doing": return "task_doing"
        case "in-review": return "task_review"
        case "done": return "task_done"
        case "canceled": return "task_canceled"
        default: return "task_todo"
        }
    }

    var body: some View {
        IconImage(name: iconName, size: size)
            .foregroundStyle(color)
            .accessibilityLabel(status.title)
    }
}

private func taskStatusColor(hex: String) -> Color? {
    let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard value.count == 6 else { return nil }
    var rgb = 0
    for character in value {
        let digit: Int
        switch character {
        case "0": digit = 0
        case "1": digit = 1
        case "2": digit = 2
        case "3": digit = 3
        case "4": digit = 4
        case "5": digit = 5
        case "6": digit = 6
        case "7": digit = 7
        case "8": digit = 8
        case "9": digit = 9
        case "a", "A": digit = 10
        case "b", "B": digit = 11
        case "c", "C": digit = 12
        case "d", "D": digit = 13
        case "e", "E": digit = 14
        case "f", "F": digit = 15
        default: return nil
        }
        rgb = rgb * 16 + digit
    }
    let radix = 256
    return Color(
        red: Double(rgb / radix / radix) / 255.0,
        green: Double((rgb / radix) % radix) / 255.0,
        blue: Double(rgb % radix) / 255.0
    )
}

#if !SKIP && os(iOS)
private struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.cameraCaptureMode = .photo
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        let onCancel: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage else {
                onCancel()
                return
            }
            onCapture(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
#endif

private struct IconImage: View {
    let name: String
    let size: CGFloat

    init(name: String, size: CGFloat = 20) {
        self.name = name
        self.size = size
    }

    private static let assetBundle: Bundle = {
        #if os(macOS) && !SKIP
        if let bundleURL = Bundle.main.resourceURL?
                .appendingPathComponent("logseq-chat_LogseqChat.bundle"),
           let bundle = Bundle(url: bundleURL) {
            return bundle
        }
        #endif
        return Bundle.module
    }()

    var body: some View {
        Image(name, bundle: Self.assetBundle)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
