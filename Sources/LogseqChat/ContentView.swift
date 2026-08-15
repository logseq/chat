import SwiftUI
import LogseqChatModel
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

struct ContentView: View {
    private static let blockListTopID = "block-list-top"
    private static let blockListBottomID = "block-list-bottom"
    @State private var store: LogseqChatStore
    @State private var authentication: LogseqAuthenticationStore
    @State private var searchText = ""
    @State private var searchPresented = false
    @State private var composerExpanded = false
    @State private var searchExpanded = false
    @State private var settingsPresented = false
    @State private var fileImporterPresented = false
    @State private var selectedTaskStatus: LogseqTaskStatus?
    @State private var editingBlock: LogseqBlock?
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
    @State private var graphSyncGeneration = 0
    @State private var composerInputGeneration = 0
    @State private var draft = ""
    @AppStorage("logseq.baseURL") private var baseURL = "http://127.0.0.1:8787"
    @AppStorage("logseq.selectedGraphId") private var selectedGraphID = ""
    @AppStorage("logseq.composerDraft") private var persistedDraft = ""
    @FocusState private var composerFocused: Bool
    @FocusState private var searchFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    init(store: LogseqChatStore, authentication: LogseqAuthenticationStore) {
        _store = State(initialValue: store)
        _authentication = State(initialValue: authentication)
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
            await store.runRefreshLoop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.refreshSoon()
            }
        }
        .onChange(of: store.snapshot.selectedGraphId) { _, graphID in
            guard let graphID, !graphID.isEmpty else { return }
            selectedGraphID = graphID
            guard authentication.state == .signedIn else { return }
            startGraphSync(graphID)
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
                        await authentication.signOut()
                        graphSyncGeneration += 1
                        selectedGraphID = ""
                        store.configure(baseURL: baseURL, token: "", refreshAfterApply: false)
                    }
                }
            )
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
        #if SKIP
        Group {
            if authentication.state == .signedIn {
                authenticatedContent
            } else {
                LogseqLoginView(authentication: authentication) {
                    connectWithCurrentAccessToken()
                }
            }
        }
        #else
        authenticatedContent
        #endif
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
            Text(verbatim: "Select an unencrypted Logseq graph to download and sync on this device.")
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
                                            Text(verbatim: "Encrypted graphs will be supported after unencrypted sync is verified.")
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
                            .disabled(graph.isEncrypted || !graph.isReady)
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

    @ViewBuilder private var appShell: some View {
        #if SKIP
            mainContent
            #else
            NavigationStack {
                mainContent
                    .platformSearchable(
                        enabled: !composerExpanded,
                        text: $searchText,
                        isPresented: $searchPresented,
                        prompt: "Search blocks"
                    )
                    .platformSearchFocused($searchFocused)
                    .onSubmit(of: .search) {
                        store.search(searchText)
                    }
                    .onChange(of: searchText) { _, query in
                        store.searchLocal(query)
                    }
                    .onChange(of: searchPresented) { _, presented in
                        handleSearchPresentationChanged(presented)
                    }
                    .platformRootNavigationChromeHidden()
                    .platformBottomComposerToolbar(
                        showsComposer: shouldShowToolbarComposer,
                        showsSearch: shouldShowSearchToolbarItem
                    ) {
                        bottomToolbarComposer
                            .platformBottomComposerWidth()
                    }
            }
        #endif
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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if shouldShowExpandedComposer {
                    floatingComposer
                        .platformFloatingComposerInset()
                }
            }
        #endif
    }

    private var stackedContent: some View {
        ZStack(alignment: .top) {
            blockList
            header
        }
        .background(appBackground)
    }

    private var shouldShowComposer: Bool {
        #if SKIP
        return !searchExpanded
        #else
        return !searchPresented
        #endif
    }

    private var shouldShowToolbarComposer: Bool {
        #if SKIP
        return false
        #else
        return shouldShowComposer && !composerExpanded
        #endif
    }

    private var shouldShowSearchToolbarItem: Bool {
        #if SKIP
        return false
        #else
        return !composerExpanded
        #endif
    }

    private var shouldShowExpandedComposer: Bool {
        shouldShowComposer && composerExpanded
    }

    private var graphSubtitle: String {
        if let graphName = store.snapshot.graphName, !graphName.isEmpty {
            return graphName
        }
        let graphID = store.snapshot.selectedGraphId ?? selectedGraphID
        return graphID.isEmpty ? "Choose a graph" : graphID
    }

    private var databasePath: String {
        LogseqChatRuntime.shared.databasePath
    }

    private var selectedGraphDatabasePath: String? {
        #if !SKIP
        let graphID = store.snapshot.selectedGraphId ?? selectedGraphID
        guard !graphID.isEmpty else { return nil }
        let directoryName = graphID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? graphID
        let databaseURL = URL(fileURLWithPath: databasePath)
            .deletingLastPathComponent()
            .appendingPathComponent("graphs")
            .appendingPathComponent(directoryName)
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
                    startGraphSync(selectedGraphID)
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
        _ = await store.bootstrapSelectedGraph(
            graphID: selectedGraphID,
            baseURL: baseURL,
            accessToken: "",
            allowSnapshotDownload: false
        )
    }

    @ViewBuilder private var authenticatedContent: some View {
        if store.snapshot.selectedGraphId == nil {
            graphPicker
        } else {
            appShell
        }
    }

    private func startGraphSync(_ graphID: String) {
        graphSyncGeneration += 1
        let generation = graphSyncGeneration
        Task {
            guard let accessToken = try? await authentication.accessToken() else { return }
            guard await store.bootstrapSelectedGraph(
                graphID: graphID,
                baseURL: baseURL,
                accessToken: accessToken
            ) else { return }
            while generation == graphSyncGeneration && authentication.state == .signedIn {
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
                        forceSnapshot: true
                    ) else { return }
                }
                if generation == graphSyncGeneration {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
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
            #if SKIP
            if searchExpanded {
                searchBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            #endif
        }
        .platformFloatingHeaderInset()
        .platformHeaderChrome()
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(verbatim: graphSubtitle)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            syncIndicatorControl
            settingsControl
        }
        .padding(.horizontal, 20)
        .padding(.top, 0)
        .padding(.bottom, 8)
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

    private var searchBar: some View {
        HStack(spacing: 10) {
            TextField("Search blocks", text: $searchText)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit {
                    store.search(searchText)
                }
                .onChange(of: searchText) { _, query in
                    store.searchLocal(query)
                }
                .accessibilityIdentifier("field.search")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    store.searchLocal("")
                } label: {
                    IconImage(name: "close")
                        .frame(width: 18, height: 18)
                }
                .platformGlassButtonStyle()
                .platformCircleButtonShape()
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("button.search.clear")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .platformGlassContainer()
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
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
                        ForEach(store.sections) { section in
                            Text(verbatim: section.title)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.top, 8)
                            ForEach(section.blocks) { block in
                                if block.kind == "asset" {
                                    BlockRow(
                                        block: block,
                                        onOpenAsset: { openAsset(block) }
                                    )
                                } else {
                                    BlockRow(
                                        block: block,
                                        statuses: availableTaskStatuses,
                                        onEdit: { handleBlockTap(block) },
                                        onStatusChange: { status in
                                            store.updateStatus(block: block, status: status)
                                        }
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
                } else if newBlocks.count > oldBlocks.count && store.snapshot.query.isEmpty {
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

    private var blockListContentTopPadding: CGFloat {
        #if SKIP
        return searchExpanded ? 180.0 : 60.0
        #else
        return 60.0
        #endif
    }

    private var blockListContentBottomPadding: CGFloat {
        72.0
    }

    private func handleBlockTap(_ block: LogseqBlock) {
        guard !composerExpanded else {
            dismissComposerEditing()
            return
        }
        editBlock(block)
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
        guard let path = block.localPath, !path.isEmpty else { return }
        #if !SKIP && os(iOS)
        previewAssetURL = URL(fileURLWithPath: path)
        #elseif SKIP
        AndroidAssetImporter.openFile(path: path, contentType: block.assetType ?? "application/octet-stream")
        #endif
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard !store.snapshot.blocks.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(Self.blockListBottomID, anchor: .bottom)
        }
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

    #if !SKIP
    private var bottomToolbarComposer: some View {
        toolbarCollapsedComposer
    }
    #endif

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

    #if !SKIP
    private var toolbarCollapsedComposer: some View {
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
        .accessibilityIdentifier("button.composer.expand")
    }
    #endif

    private var expandedComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Capture", text: $draft, axis: .vertical)
                .id(composerInputGeneration)
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

    private func expandSearch() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            searchExpanded = true
            composerExpanded = false
        }
        focusSearch()
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
        composerInputGeneration += 1
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
        composerInputGeneration += 1
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
        var result = LogseqTaskStatus.builtIn
        var identities = Set(result.map { $0.ident ?? $0.uuid })
        let remoteStatuses = store.snapshot.taskStatuses ?? []
        for status in remoteStatuses + store.snapshot.blocks.compactMap(\.status) {
            let identity = status.ident ?? status.uuid
            if identities.insert(identity).inserted {
                result.append(status)
            }
        }
        return result
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
            localPath: metadata.path
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

private struct LogseqLoginView: View {
    let authentication: LogseqAuthenticationStore
    let onSignedIn: () -> Void
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("Sign in to Logseq")
                .font(.title2.weight(.semibold))
            TextField("Email", text: $username)
                .platformLoginTextInput()
                .accessibilityIdentifier("field.email")
            SecureField("Password", text: $password)
                .accessibilityIdentifier("field.password")
            if let message = authentication.errorMessage {
                Text(message)
                    .foregroundStyle(.red)
            }
            Button(authentication.state == .signingIn ? "Signing In…" : "Sign In") {
                Task {
                    await authentication.signIn(username: username, password: password)
                    if authentication.state == .signedIn {
                        password = ""
                        onSignedIn()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(authentication.state == .signingIn)
            .accessibilityIdentifier("button.sign-in")
        }
        .padding(32)
    }
}

extension View {
    @ViewBuilder public func platformLoginTextInput() -> some View {
        #if os(iOS) || SKIP
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
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
        let presentation = Binding(
            get: { enabled && isPresented.wrappedValue },
            set: { value in
                if enabled || !value {
                    isPresented.wrappedValue = value
                }
            }
        )
        self.searchable(
            text: text,
            isPresented: presentation,
            placement: .automatic,
            prompt: Text(verbatim: prompt)
        )
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

    @ViewBuilder public func platformBottomComposerWidth() -> some View {
        #if os(iOS)
        self.frame(
            width: max(220.0, UIScreen.main.bounds.width - 112.0),
            alignment: .leading
        )
        #else
        self.frame(maxWidth: .infinity, alignment: .leading)
        #endif
    }

    @ViewBuilder public func platformBottomComposerToolbar<Content: View>(
        showsComposer: Bool,
        showsSearch: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.toolbar {
                if showsComposer {
                    ToolbarItem(placement: .bottomBar) {
                        content()
                    }
                }
                if showsSearch {
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    DefaultToolbarItem(kind: .search, placement: .bottomBar)
                }
            }
            .searchToolbarBehavior(.minimize)
        } else {
            self.toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    if showsComposer {
                        content()
                        Spacer(minLength: 0)
                    }
                }
            }
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

    @ViewBuilder public func platformHeaderChrome() -> some View {
        #if !SKIP
        self.background(.ultraThinMaterial)
            .overlay(alignment: .bottom) {
                Divider()
                    .opacity(0.2)
            }
        #else
        self
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
    var onStatusChange: ((LogseqTaskStatus) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if block.kind == "asset" {
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
                            }
                        } label: {
                            TaskStatusIcon(status: status, size: 24)
                                .frame(width: 24, height: 24)
                        }
                        .accessibilityLabel("Task status")
                        .platformIconMenuStyle()
                    }
                    Text(verbatim: block.title.isEmpty ? "Untitled block" : block.title)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .padding(.top, 2)
                }
            }
            if !block.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(block.tags) { tag in
                        Text(verbatim: "#" + tag.title)
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                }
            }
            if !block.references.isEmpty {
                Text(verbatim: block.references.map { "[[\($0.title)]]" }.joined(separator: "  "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
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
    }
}

private struct AssetPreview: View {
    let block: LogseqBlock
    let onOpen: (() -> Void)?

    var body: some View {
        #if !SKIP && os(iOS)
        if let path = block.localPath, isImage, let image = UIImage(contentsOfFile: path) {
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
        } else if let path = block.localPath, isAudio {
            VStack(alignment: .leading, spacing: 8) {
                assetTitle
                AssetAudioPlayer(path: path)
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

private struct TaskStatusIcon: View {
    let status: LogseqTaskStatus
    let size: CGFloat

    init(status: LogseqTaskStatus, size: CGFloat = 16) {
        self.status = status
        self.size = size
    }

    private var kind: String {
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
        switch kind {
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
        switch kind {
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

private struct ErrorBanner: View {
    let error: LogseqChatCoreError

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: error.code)
                .font(.headline)
            Text(verbatim: error.message)
                .font(.subheadline)
        }
        .foregroundStyle(Color(red: 0.48, green: 0.08, blue: 0.08))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(red: 1.0, green: 0.90, blue: 0.90))
        .cornerRadius(16)
    }
}

private struct EmptyBlocksView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "No cached blocks")
                .font(.headline)
            Text(verbatim: "Connect to Logseq or add a local block to start.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white.opacity(0.65))
        .cornerRadius(18)
    }
}
