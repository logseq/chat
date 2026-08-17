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
        VStack(spacing: 4) {
            Capsule()
                .frame(width: SidebarChromeMetrics.menuGlyphWidth, height: 2)
            Capsule()
                .frame(width: SidebarChromeMetrics.menuGlyphWidth, height: 2)
            Capsule()
                .frame(width: SidebarChromeMetrics.menuGlyphWidth, height: 2)
        }
        .frame(
            width: SidebarChromeMetrics.menuVisualFrame,
            height: SidebarChromeMetrics.menuVisualFrame
        )
    }
}

@MainActor @Observable final class SidebarMotionState {
    var isPresented = false
    var isAnimating = false
    var dragOffset: CGFloat = 0

    func setPresented(_ presented: Bool) {
        guard presented != isPresented || abs(dragOffset) > 0 else { return }
        isAnimating = true
        #if SKIP
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            isPresented = presented
            dragOffset = 0
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
            let width = min(geometry.size.width * 0.84, 360)
            let baseOffset = motion.isPresented ? width : 0
            let contentOffset = min(max(baseOffset + motion.dragOffset, 0), width)
            let progress = width > 0 ? contentOffset / width : 0
            let isDragging = abs(motion.dragOffset) > 0

            ZStack(alignment: .leading) {
                #if SKIP
                ComposeView { _ in
                    BackHandler(enabled: motion.isPresented) {
                        motion.setPresented(false)
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
                    .offset(x: -20 * (1 - progress))

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
                                motion.setPresented(false)
                            } label: {
                                Color.black.opacity(0.001)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Close sidebar")
                            .accessibilityIdentifier("button.sidebar.dismiss")
                        }
                    }
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 40 * progress))
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
                motion.setPresented(SidebarDragPolicy.presentedAfterDrag(
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
    @State private var searchText = ""
    @State private var searchPresented = false
    @State private var isRestoringSearchProjection = false
    @State private var composerExpanded = false
    @State private var searchExpanded = false
    @State private var settingsPresented = false
    @State private var searchPagePresented = false
    @State private var graphsPresented = false
    @State private var graphPasswordPresented = false
    @State private var graphPassword = ""
    @State private var graphUnlockInProgress = false
    @State private var fileImporterPresented = false
    @State private var selectedTaskStatus: LogseqTaskStatus?
    @State private var editingBlock: LogseqBlock?
    @State private var blocksPendingDeletion: [LogseqBlock] = []
    @State private var outlinerDeleteConfirmationPending = false
    @State private var outlinerKeyboardDismissalPending = false
    @State private var sidebarMotion = SidebarMotionState()
    @State private var appNavigationPath: [AppNavigationRoute] = []
    @State private var pendingNodeRoutes: Set<AppNavigationRoute> = []
    #if !SKIP
    @State private var taskStatusPickerPresented = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var photoPickerPresented = false
    #if os(iOS)
    @State private var cameraPresented = false
    @State private var previewAssetURL: URL?
    #endif
    #endif
    @State private var hasAutoScrolledInitially = false
    @State private var draft = ""
    @AppStorage("logseq.baseURL") private var baseURL = "http://127.0.0.1:8787"
    @AppStorage("logseq.selectedGraphId") private var selectedGraphID = ""
    @AppStorage("logseq.composerDraft") private var persistedDraft = ""
    @AppStorage("logseq.contentMode") private var contentModeRaw = LogseqContentMode.chat.rawValue
    @FocusState private var composerFocused: Bool
    @FocusState private var searchFocused: Bool
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

    var body: some View {
        rootContent
        .task {
            draft = persistedDraft
            #if DEBUG
            print("LogseqChat debug: content task started")
            #endif
            store.open(path: databasePath)
            #if DEBUG
            print("LogseqChat debug: local store opened")
            #endif
            await restoreCachedGraphIfAvailable()
            await authentication.restore()
            #if DEBUG
            print("LogseqChat debug: authentication restore finished state=\(authentication.state.rawValue)")
            #endif
            connectWithCurrentAccessToken()
            await store.runPendingSyncLoop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.syncPending()
                if authentication.state == .signedIn, !selectedGraphID.isEmpty {
                    beginGraphAccess(selectedGraphID)
                }
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
        .onChange(of: store.snapshot.outlinerState.editing?.uuid) { _, uuid in
            if uuid == nil {
                outlinerKeyboardDismissalPending = false
            }
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
        .sheet(isPresented: $searchPagePresented) {
            NodeSearchView(store: store) { hit in
                openNodeRoute(hit.uuid)
            }
        }
        .sheet(isPresented: $graphPasswordPresented) {
            NavigationStack {
                Form {
                    SecureField("Graph password", text: $graphPassword)
                        .textContentType(.password)
                    if let error = store.lastError {
                        Text(verbatim: error.message)
                            .foregroundStyle(.red)
                    }
                }
                .navigationTitle("Unlock graph")
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
        .quickLookPreview($previewAssetURL)
        #endif
        .onChange(of: selectedPhotoItems) { _, items in
            importPhotos(items)
        }
        #endif
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
            if let message = authentication.errorMessage {
                Text(verbatim: message)
                    .foregroundStyle(.red)
            }
            if let error = store.lastError {
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
                                selectedGraphID = graph.id
                                store.selectGraph(graph.id)
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
                                .background(Color.white.opacity(0.7))
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
                let closedNodes = AppNavigationPathPolicy.nodeCount(previousPath)
                    - AppNavigationPathPolicy.nodeCount(path)
                if closedNodes > 0 {
                    for _ in 0..<closedNodes { store.closeNode() }
                }
            }
            #if os(iOS)
            .overlay(alignment: .bottom) {
                iosBottomChrome
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
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(appBackground)
        .navigationTitle(nodeProjectionTitle(uuid: uuid))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder private func nodeProjectionContent(_ projection: LogseqNodeProjection) -> some View {
        if projection.isTag {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
            RelatedBlocksSection(
                title: "Tagged nodes",
                emptyTitle: projection.relatedBlocks.isEmpty ? "No tagged nodes" : nil,
                blocks: projection.relatedBlocks,
                accessibilityIdentifier: "section.tag.tagged-nodes",
                onOpenMarkupLink: openMarkupLink
            )
                }
                .padding()
            }
        } else {
            OutlinerView(
                rows: projection.outlinerRows,
                sections: store.sections(for: projection),
                editing: projection.outlinerState.editing,
                selectedBlockIDs: Set(projection.outlinerState.selectedBlockIds),
                statuses: availableTaskStatuses,
                error: store.lastError,
                hasOlderJournals: false,
                topPadding: 16,
                bottomPadding: blockListContentBottomPadding,
                sendEvent: store.outlinerEvent,
                onBeginInteraction: beginOutlinerInteraction,
                onZoomBlock: openOutlinerNode,
                onOpenMarkupLink: openMarkupLink,
                onLoadOlderJournals: {},
                relatedTitle: projection.relatedBlocks.isEmpty ? nil : "Linked references",
                relatedBlocks: projection.relatedBlocks
            )
        }
    }

    private func nodeProjectionTitle(uuid: String) -> String {
        guard let projection = store.snapshot.nodeRoutes.last(where: { $0.uuid == uuid }) else {
            return markupTargetTitle(uuid: uuid) ?? "Node"
        }
        if projection.isTag { return "#\(projection.page.title)" }
        return projection.blocks.first(where: { $0.uuid == uuid })?.title ?? projection.page.title
    }

    private var navigationMainContent: some View {
        mainContent
            .platformRootNavigationChromeHidden()
    }
    #endif

    private var sidebarContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
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
                    HStack {
                        Text(verbatim: graphSubtitle)
                            .font(.headline)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Spacer()
                        Text(verbatim: "⌄")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .accessibilityLabel("Switch graph")
                .accessibilityIdentifier("button.graph-switch")
                .padding(.bottom, 20)

                ForEach(SidebarContentItem.allCases, id: \.rawValue) { item in
                    sidebarItem(item)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            #if SKIP
            .padding(.top, SidebarChromeMetrics.androidHeaderTopPadding)
            #else
            .padding(.top, SidebarChromeMetrics.iOSHeaderTopPadding)
            #endif
        }
    }

    @ViewBuilder private func sidebarItem(_ item: SidebarContentItem) -> some View {
        switch item {
        case .journals:
            Button {
                openJournals()
            } label: {
                HStack {
                    Text(verbatim: item.title)
                        .font(.body)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.001))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(item.accessibilityIdentifier)
        case .graphs:
            Button {
                openGraphs()
            } label: {
                HStack {
                    Text(verbatim: item.title)
                        .font(.body)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.001))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(item.accessibilityIdentifier)
        case .favorites:
            sidebarSection(
                title: item.title,
                identifier: item.accessibilityIdentifier,
                pages: store.snapshot.favorites
            )
        case .recent:
            sidebarSection(
                title: item.title,
                identifier: item.accessibilityIdentifier,
                pages: store.snapshot.recentPages
            )
        }
    }

    private func sidebarSection(
        title: String,
        identifier: String,
        pages: [LogseqSidebarPage]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            ForEach(pages) { page in
                Button {
                    openSidebarPage(page)
                } label: {
                    HStack {
                        Text(verbatim: page.title)
                            .font(.body)
                            .lineLimit(1)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.001))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("link.sidebar.page.\(page.uuid)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(identifier)
    }

    private func switchGraph(to graph: LogseqGraph) {
        guard sidebarMotion.isPresented, !sidebarMotion.isAnimating,
              abs(sidebarMotion.dragOffset) == 0 else { return }
        sidebarMotion.setPresented(false)
        searchText = ""
        if graph.id == store.snapshot.selectedGraphId {
            store.clearSelectedPage()
            return
        }
        selectedGraphID = graph.id
        store.selectGraph(graph.id)
    }

    private func openSidebarPage(_ page: LogseqSidebarPage) {
        guard sidebarMotion.isPresented, !sidebarMotion.isAnimating,
              abs(sidebarMotion.dragOffset) == 0 else { return }
        sidebarMotion.setPresented(false)
        graphsPresented = false
        searchText = ""
        store.selectPage(page.uuid)
    }

    private func openJournals() {
        guard sidebarMotion.isPresented, !sidebarMotion.isAnimating,
              abs(sidebarMotion.dragOffset) == 0 else { return }
        sidebarMotion.setPresented(false)
        graphsPresented = false
        searchText = ""
        store.clearSelectedPage()
    }

    private func openGraphs() {
        guard sidebarMotion.isPresented, !sidebarMotion.isAnimating,
              abs(sidebarMotion.dragOffset) == 0 else { return }
        sidebarMotion.setPresented(false)
        graphsPresented = true
    }

    private func openManagedGraph(_ graph: LogseqGraph) {
        graphsPresented = false
        searchText = ""
        if graph.id == store.snapshot.selectedGraphId,
           LogseqGraphLocalStorage.isDownloaded(databasePath: databasePath, graphID: graph.id) {
            store.clearSelectedPage()
            return
        }
        selectedGraphID = graph.id
        store.selectGraph(graph.id)
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
                open: openManagedGraph,
                deleteGraph: deleteManagedGraph
            )
        } else {
            if presentedContentMode == .outliner {
                OutlinerView(
                    rows: store.snapshot.outlinerRows,
                    sections: store.sections(for: LogseqContentMode.outliner),
                    editing: presentedOutlinerEditing,
                    selectedBlockIDs: outlinerSelectedBlockIDs,
                    statuses: availableTaskStatuses,
                    error: store.lastError,
                    hasOlderJournals: store.snapshot.hasOlderJournals,
                    topPadding: blockListContentTopPadding,
                    bottomPadding: blockListContentBottomPadding,
                    sendEvent: store.outlinerEvent,
                    onBeginInteraction: beginOutlinerInteraction,
                    onZoomBlock: openOutlinerNode,
                    onOpenMarkupLink: openMarkupLink,
                    onLoadOlderJournals: store.loadOlderJournals,
                    relatedTitle: selectedTagPageRelatedTitle,
                    relatedBlocks: selectedTagPageRelatedBlocks
                )
            } else {
                blockList
            }
        }
    }

    // Tag (class) pages opened from the sidebar list their tagged objects, the
    // same way tag node routes do.
    private var selectedTagPageRelatedBlocks: [LogseqBlock] {
        guard store.snapshot.selectedPage != nil,
              store.snapshot.selectedPageIsTag == true else { return [] }
        return store.snapshot.relatedBlocks ?? []
    }

    private var selectedTagPageRelatedTitle: String? {
        selectedTagPageRelatedBlocks.isEmpty ? nil : "Tagged nodes"
    }

    private func markupTargetTitle(uuid: String) -> String? {
        for block in store.snapshot.blocks {
            if let target = (block.references + block.tags).first(where: { $0.uuid == uuid }) {
                return target.title
            }
        }
        return nil
    }

    private func beginOutlinerInteraction() {
        outlinerKeyboardDismissalPending = false
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
        pendingNodeRoutes.insert(route)
        // Navigate only after the core resolved the node from local data, so
        // an unknown node can never leave an endless spinner behind.
        store.openNode(uuid) { resolved in
            pendingNodeRoutes.remove(route)
            guard resolved,
                  AppNavigationPathPolicy.shouldAppend(route, to: appNavigationPath)
            else { return }
            appNavigationPath.append(route)
        }
    }
    #endif

    private var shouldShowComposer: Bool {
        #if SKIP
        return store.snapshot.selectedPage == nil && !searchExpanded
        #else
        return store.snapshot.selectedPage == nil && !searchPresented
        #endif
    }

    private var shouldShowExpandedComposer: Bool {
        shouldShowComposer && composerExpanded
    }

    private var bottomChromePresentation: BottomChromePresentation {
        #if SKIP
        let isSearching = searchExpanded
        #else
        let isSearching = searchPresented
        #endif
        return BottomChromePolicy.presentation(
            contentMode: presentedContentMode,
            hasSelectedPage: store.snapshot.selectedPage != nil,
            isSearching: isSearching,
            composerExpanded: composerExpanded,
            hasOutlinerSelection: !outlinerSelectedBlockIDs.isEmpty,
            isEditingOutlinerBlock: presentedOutlinerEditing != nil
        )
    }

    private var graphSubtitle: String {
        if let graphName = store.snapshot.graphName, !graphName.isEmpty {
            return graphName
        }
        let graphID = store.snapshot.selectedGraphId ?? selectedGraphID
        return graphID.isEmpty ? "Choose a graph" : graphID
    }

    private var contentMode: LogseqContentMode {
        get { LogseqContentMode(rawValue: contentModeRaw) ?? .chat }
        nonmutating set { contentModeRaw = newValue.rawValue }
    }

    private var presentedContentMode: LogseqContentMode {
        contentMode.presentationMode(
            isSearching: store.snapshot.isSearching,
            hasSelectedPage: store.snapshot.selectedPage != nil
        )
    }

    private var outlinerEditing: LogseqOutlinerEditing? {
        store.snapshot.outlinerState.editing
    }

    private var presentedOutlinerEditing: LogseqOutlinerEditing? {
        OutlinerKeyboardPresentationPolicy.presentedEditing(
            coreEditing: outlinerEditing,
            dismissalPending: outlinerKeyboardDismissalPending
        )
    }

    private var outlinerSelectedBlockIDs: Set<String> {
        Set(store.snapshot.outlinerState.selectedBlockIds)
    }

    private var zoomedOutlinerBlock: LogseqBlock? {
        guard presentedContentMode == .outliner,
              let id = store.snapshot.outlinerState.zoomedBlockId else { return nil }
        return store.snapshot.blocks.first(where: { $0.uuid == id })
    }

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { !blocksPendingDeletion.isEmpty },
            set: { if !$0 { blocksPendingDeletion = [] } }
        )
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
                await store.configureAndSelectGraph(
                    baseURL: baseURL,
                    token: accessToken,
                    selectedGraphID: selectedGraphID.isEmpty ? nil : selectedGraphID
                )
                if !selectedGraphID.isEmpty {
                    beginGraphAccess(selectedGraphID)
                }
            } catch {
                #if DEBUG
                print("LogseqChat debug: access token request failed: \(error.localizedDescription)")
                #endif
                logger.error("Could not acquire Cognito access token: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func restoreCachedGraphIfAvailable() async {
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
        } else {
            appShell
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
                    if snapshotRequired {
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

    private var platformAppBackground: Color {
        #if os(iOS) && !SKIP
        Color(uiColor: .systemGroupedBackground)
        #elseif os(macOS) && !SKIP
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(red: 0.95, green: 0.96, blue: 0.96)
        #endif
    }

    private var header: some View {
        VStack(spacing: 0) {
            topBar
        }
        .platformFloatingHeaderInset()
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
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
                } else if sidebarActivationAvailable {
                    sidebarMotion.setPresented(!sidebarMotion.isPresented)
                }
            } label: {
                if zoomedOutlinerBlock != nil {
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
            .buttonStyle(.plain)
            .disabled(zoomedOutlinerBlock == nil && !sidebarActivationAvailable)
            .accessibilityLabel(zoomedOutlinerBlock == nil ? "Open sidebar" : "Back")
            .accessibilityIdentifier(zoomedOutlinerBlock == nil ? "button.sidebar" : "button.outliner.zoom-out")
            Text(verbatim: zoomedOutlinerBlock?.title ?? store.snapshot.selectedPage?.title ?? graphSubtitle)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if !store.snapshot.isSearching,
               LogseqContentMode.supportsModeSwitch(
                   hasSelectedPage: store.snapshot.selectedPage != nil
               ) {
                Button {
                    finishOutlinerEditing()
                    composerExpanded = false
                    composerFocused = false
                    contentMode = contentMode.toggled
                } label: {
                    ContentModeIcon(mode: contentMode.toggled)
                }
                .frame(width: 44, height: 44)
                .buttonStyle(.plain)
                .accessibilityLabel(contentMode == .chat ? "Show outliner" : "Show chat")
                .accessibilityIdentifier("button.content-mode")
            }
            syncIndicatorControl
            settingsControl
        }
        .padding(.horizontal, 20)
        .padding(.top, 0)
        .padding(.bottom, SidebarChromeMetrics.headerBottomPadding)
    }

    private var hasUnconfirmedSyncChanges: Bool {
        store.snapshot.blocks.contains { block in
            block.syncStatus == "pending"
                || block.syncStatus == "submitted"
                || block.syncStatus == "failed"
        }
    }

    private var syncIndicatorColor: Color {
        if store.snapshot.syncConnected == true && !hasUnconfirmedSyncChanges {
            return .green
        }
        return .yellow
    }

    private var syncIndicatorLabel: String {
        if hasUnconfirmedSyncChanges {
            return "Sync pending"
        }
        return store.snapshot.syncConnected == true ? "Synced" : "Not connected"
    }

    private var syncIndicatorAccessibilityIdentifier: String {
        if store.cursorAdvancedAfterMutation {
            return "sync.cursor-advanced"
        }
        return store.snapshot.syncConnected == true ? "sync.connected" : "sync.disconnected"
    }

    private var syncIndicatorControl: some View {
        Button {
            settingsPresented = true
        } label: {
            Circle()
                .fill(syncIndicatorColor)
                .frame(width: 10, height: 10)
        }
        .frame(width: 44, height: 44)
        .buttonStyle(.plain)
        .accessibilityLabel(syncIndicatorLabel)
        .accessibilityIdentifier(syncIndicatorAccessibilityIdentifier)
    }

    private var settingsControl: some View {
        Button {
            settingsPresented = true
        } label: {
            IconImage(name: "more_horiz")
                .frame(width: 24, height: 24)
        }
        .frame(width: 52, height: 52)
        .platformGlassButtonStyle()
        .platformCircleButtonShape()
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("button.connection")
    }

    private var blockList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Color.clear
                        .frame(height: blockListContentTopPadding)
                        .id(Self.blockListTopID)
                    if let error = store.lastError {
                        ErrorBanner(error: error)
                    }
                    if store.sections.isEmpty {
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
                let restoringSearchProjection = isRestoringSearchProjection
                if restoringSearchProjection {
                    isRestoringSearchProjection = false
                }
                if !hasAutoScrolledInitially {
                    autoScrollOnFirstAppear(proxy)
                } else if BlockListUpdatePolicy.shouldScrollToBottom(
                    oldBlockIDs: Set(oldBlocks.map(\.uuid)),
                    newBlockIDs: Set(newBlocks.map(\.uuid)),
                    queryIsEmpty: store.snapshot.query.isEmpty,
                    isRestoringSearchProjection: restoringSearchProjection
                ) {
                    scrollToBottom(proxy)
                }
            }
            .onChange(of: store.snapshot.query) { oldQuery, newQuery in
                if oldQuery.isEmpty && !newQuery.isEmpty {
                    scrollToTop(proxy)
                }
            }
        }
    }

    private func confirmDelete(_ block: LogseqBlock) {
        blocksPendingDeletion = [block]
    }

    private var blockListContentTopPadding: CGFloat {
        #if SKIP
        return searchExpanded ? 180.0 : 60.0
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
                blocksPendingDeletion = store.snapshot.blocks.filter { ids.contains($0.uuid) }
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
                fileImporterPresented = true
            case "takePhoto":
                #if !SKIP && os(iOS)
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    cameraPresented = true
                }
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

    private func scrollToTop(_ proxy: ScrollViewProxy) {
        guard !store.snapshot.blocks.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(Self.blockListTopID, anchor: .top)
        }
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
                    .padding(.bottom, MobileChromePolicy.bottomControlScreenEdgeInset)
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
        if action == .hideKeyboard {
            outlinerKeyboardDismissalPending = true
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }
        store.outlinerEvent(LogseqOutlinerEvent(type: "toolbar", action: eventValue))
    }

    private func handleOutlinerSelectionToolbarAction(_ action: OutlinerToolbarAction) {
        guard let eventValue = action.eventValue else { return }
        store.outlinerEvent(LogseqOutlinerEvent(type: "toolbar", action: eventValue))
    }

    private var outlinerAutocompleteCandidates: [LogseqOutlinerAutocompleteCandidate] {
        store.snapshot.outlinerAutocompleteCandidates
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
                    #else
                    // Bottom-anchored iOS menus place the first action nearest the trigger.
                    Button {
                        fileImporterPresented = true
                    } label: {
                        HStack {
                            Image(systemName: "paperclip")
                            Text("File")
                        }
                    }
                    #if os(iOS)
                    Button {
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
                        photoPickerPresented = true
                    } label: {
                        HStack {
                            Image(systemName: "photo.on.rectangle.angled")
                            Text("Photo")
                        }
                    }
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

    private func focusSearch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            searchFocused = true
        }
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

    private func handleSearchPresentationChanged(_ presented: Bool) {
        guard !presented else {
            dismissComposerEditing()
            return
        }
        searchFocused = false
        clearSearch()
    }

    private func clearSearch() {
        guard !searchText.isEmpty else { return }
        searchText = ""
        store.searchLocal("")
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
                    logger.error("Photo import failed: \(String(describing: error), privacy: .public)")
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
                logger.error("Camera import failed: \(String(describing: error), privacy: .public)")
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
            localPath: LocalAssetPath.storedPath(metadata.path)
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
                    logger.error("Asset import failed: \(String(describing: error), privacy: .public)")
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

    var body: some View {
        NavigationStack {
            Form {
                Section("Logseq API") {
                    TextField("Base URL", text: $baseURL)
                        .accessibilityIdentifier("field.base-url")
                }
                #if !SKIP
                if let graphDatabasePath {
                    let graphDatabaseURL = URL(fileURLWithPath: graphDatabasePath)
                    Section("Graph Data") {
                        ShareLink(item: graphDatabaseURL) {
                            Text("Export Graph SQLite DB")
                        }
                        .accessibilityIdentifier("button.export-graph-database")
                    }
                }
                #endif
                Section {
                    Button("Sign Out", role: .destructive) {
                        signOut()
                    }
                    .accessibilityIdentifier("button.sign-out")
                }
            }
            .navigationTitle("Connection")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier("button.connection.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        apply()
                    }
                    .disabled(baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("button.connection.apply")
                }
            }
        }
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
    @ViewBuilder public func platformSearchable(
        enabled: Bool,
        text: Binding<String>,
        isPresented: Binding<Bool>,
        prompt: String
    ) -> some View {
        if enabled {
            self.searchable(
                text: text,
                isPresented: isPresented,
                placement: .automatic,
                prompt: Text(verbatim: prompt)
            )
        } else {
            self
        }
    }

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

    @ViewBuilder public func platformSearchFocused(_ binding: FocusState<Bool>.Binding) -> some View {
        #if os(iOS)
        if #available(iOS 18.0, *) {
            self.searchFocused(binding)
        } else {
            self
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
        self.background(Color.white.opacity(0.9))
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
        self.background(Color.white.opacity(0.82))
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
        .background(Color.white.opacity(0.72))
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
            fallback: block.title.isEmpty ? "Untitled block" : block.title
        ))
        .environment(\.openURL, OpenURLAction { url in
            guard let link = OutlinerMarkupLink(url: url) else { return .systemAction }
            onOpenMarkupLink?(link)
            return .handled
        })
        #else
        Text(verbatim: block.title.isEmpty ? "Untitled block" : block.title)
        #endif
    }
}

private struct ContentModeIcon: View {
    let mode: LogseqContentMode

    var body: some View {
        Group {
            if mode == .outliner {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        HStack(spacing: 4) {
                            Circle().frame(width: 4, height: 4)
                            Capsule().frame(width: 14, height: 2)
                        }
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(lineWidth: 1.8)
                    .frame(width: 21, height: 17)
                    .overlay {
                        VStack(spacing: 3) {
                            Capsule().frame(width: 12, height: 1.5)
                            Capsule().frame(width: 9, height: 1.5)
                        }
                    }
            }
        }
        .frame(width: 22, height: 22)
    }
}

private struct AssetPreview: View {
    let block: LogseqBlock
    let onOpen: (() -> Void)?

    var body: some View {
        #if !SKIP && os(iOS)
        if let url = LocalAssetPath.resolve(
            block.localPath,
            title: block.title,
            assetType: block.assetType
        ),
           isImage,
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
        } else if let url = LocalAssetPath.resolve(
            block.localPath,
            title: block.title,
            assetType: block.assetType
        ),
                  isAudio {
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

    private var normalizedType: String {
        let pathExtension = block.localPath.map { URL(fileURLWithPath: $0).pathExtension }
        return (block.assetType ?? pathExtension ?? "").lowercased()
    }

    private var isImage: Bool {
        normalizedType.hasPrefix("image/")
            || ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains(normalizedType)
    }

    private var isAudio: Bool {
        normalizedType.hasPrefix("audio/")
            || ["m4a", "mp3", "wav", "aac", "caf"].contains(normalizedType)
    }

    private var assetTitle: some View {
        Text(verbatim: block.title.isEmpty ? "Untitled file" : block.title)
            .font(.body)
            .fontWeight(.medium)
            .foregroundStyle(.primary)
            .lineLimit(3)
    }

    private var fileButton: some View {
        Button { onOpen?() } label: {
            HStack(spacing: 8) {
                IconImage(name: isAudio ? "audio" : "paperclip")
                    .frame(width: 18, height: 18)
                assetTitle
            }
        }
        .buttonStyle(.plain)
    }
}

#if !SKIP && os(iOS)
private struct AssetAudioPlayer: View {
    @State private var player: AVPlayer

    init(path: String) {
        _player = State(initialValue: AVPlayer(url: URL(fileURLWithPath: path)))
    }

    var body: some View {
        VideoPlayer(player: player)
            .onDisappear { player.pause() }
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
