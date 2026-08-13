import SwiftUI
import LogseqChatModel

struct ContentView: View {
    private static let blockListTopID = "block-list-top"
    private static let blockListBottomID = "block-list-bottom"
    @State private var store: LogseqChatStore
    @State private var searchText = ""
    @State private var searchPresented = false
    @State private var composerExpanded = false
    @State private var searchExpanded = false
    @State private var settingsPresented = false
    @State private var detailBlock: LogseqBlock?
    @State private var hasAutoScrolledInitially = false
    @AppStorage("logseq.baseURL") private var baseURL = "http://127.0.0.1:8787"
    @AppStorage("logseq.token") private var token = ""
    @AppStorage("logseq.composerDraft") private var draft = ""
    @FocusState private var composerFocused: Bool
    @FocusState private var searchFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    init(store: LogseqChatStore) {
        _store = State(initialValue: store)
    }

    var body: some View {
        appShell
        .task {
            store.open(path: databasePath)
            if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.configure(baseURL: baseURL, token: token)
            } else {
                store.refreshSoon()
            }
            await store.runRefreshLoop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.refreshSoon()
            }
        }
        .sheet(isPresented: $settingsPresented) {
            ConnectionSettingsView(
                baseURL: $baseURL,
                token: $token,
                apply: {
                    settingsPresented = false
                    store.configure(baseURL: baseURL, token: token)
                }
            )
        }
    }

    @ViewBuilder private var appShell: some View {
        #if SKIP
            mainContent
                .sheet(item: $detailBlock) { block in
                    BlockDetailView(block: block, store: store)
                }
            #else
            NavigationStack {
                mainContent
                    .searchable(text: $searchText, isPresented: $searchPresented, placement: .automatic, prompt: "Search blocks")
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
                    .navigationDestination(for: LogseqBlock.self) { block in
                        BlockDetailView(block: block, store: store)
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
        #else
        stackedContent
            .overlay(alignment: .bottom) {
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
        return "Not connected"
    }

    private var databasePath: String {
        LogseqChatRuntime.shared.databasePath
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
            settingsControl
        }
        .padding(.horizontal, 20)
        .padding(.top, 0)
        .padding(.bottom, 8)
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
                            VStack(alignment: .leading, spacing: 10) {
                                Text(verbatim: section.title)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                ForEach(section.blocks) { block in
                                    if composerExpanded {
                                        Button {
                                            dismissComposerEditing()
                                        } label: {
                                            BlockRow(block: block)
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                    #if SKIP
                                        Button {
                                            openBlock(block)
                                        } label: {
                                            BlockRow(block: block)
                                        }
                                        .buttonStyle(.plain)
                                    #else
                                        NavigationLink(value: block) {
                                            BlockRow(block: block)
                                        }
                                        .buttonStyle(.plain)
                                        .simultaneousGesture(TapGesture().onEnded {
                                            openBlock(block)
                                        })
                                    #endif
                                    }
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
            .onTapGesture {
                if composerExpanded {
                    dismissComposerEditing()
                }
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

    private func openBlock(_ block: LogseqBlock) {
        dismissComposerEditing()
        store.select(block)
        #if SKIP
        detailBlock = block
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
                .platformComposerLineLimit()
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 36, alignment: .topLeading)
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .accessibilityIdentifier("field.composer")
            HStack(spacing: 0) {
                Spacer()
                Button {
                    sendDraft()
                } label: {
                    IconImage(name: "arrow_upward")
                        .frame(width: 10, height: 10)
                        .frame(width: 24, height: 24)
                }
                .platformGlassProminentButtonStyle()
                .platformCircleButtonShape()
                .platformSmallControl()
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
            if composerExpanded && value.isEmpty {
                focusComposer()
            }
        }
    }

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
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            composerExpanded = true
        }
        focusComposer()
    }

    private func focusComposer() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            composerFocused = true
        }
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
    }

    private func sendDraft() {
        store.send(draft)
        draft = ""
        composerExpanded = true
        focusComposer()
    }
}

private struct ConnectionSettingsView: View {
    @Binding var baseURL: String
    @Binding var token: String
    let apply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Logseq API") {
                    TextField("Base URL", text: $baseURL)
                        .accessibilityIdentifier("field.base-url")
                    SecureField("PAT", text: $token)
                        .accessibilityIdentifier("field.pat")
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
                    .disabled(baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("button.connection.apply")
                }
            }
        }
    }
}

extension View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: block.title.isEmpty ? "Untitled block" : block.title)
                .font(.body)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(3)
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
    }
}

private struct IconImage: View {
    let name: String

    var body: some View {
        Image(name, bundle: .module)
            .resizable()
            .scaledToFit()
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
    }
}

private struct BlockDetailView: View {
    let block: LogseqBlock
    let store: LogseqChatStore
    @State private var editedTitle: String
    @State private var isEditing = false

    init(block: LogseqBlock, store: LogseqChatStore) {
        self.block = block
        self.store = store
        _editedTitle = State(initialValue: block.title)
    }

    private var currentBlock: LogseqBlock {
        store.snapshot.blocks.first { value in
            value.uuid == block.uuid
        } ?? block
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if isEditing {
                    TextField("Block text", text: $editedTitle, axis: .vertical)
                        .lineLimit(8)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.done)
                        .accessibilityIdentifier("field.block.title")
                } else {
                    Text(verbatim: currentBlock.title.isEmpty ? "Untitled block" : currentBlock.title)
                        .font(.title2)
                        .fontWeight(.semibold)
                }
                HStack(spacing: 10) {
                    Button(isEditing ? "Save" : "Edit") {
                        if isEditing {
                            store.update(block: currentBlock, title: editedTitle)
                            isEditing = false
                        } else {
                            editedTitle = currentBlock.title
                            isEditing = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isEditing && editedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("button.block.edit")
                    if isEditing {
                        Button("Cancel") {
                            editedTitle = currentBlock.title
                            isEditing = false
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("button.block.cancel")
                    }
                }
                DetailLine(label: "Type", value: currentBlock.kind)
                DetailLine(label: "Block", value: currentBlock.uuid)
                DetailLine(label: "Page", value: currentBlock.pageId)
                if let parentId = currentBlock.parentId {
                    DetailLine(label: "Parent", value: parentId)
                }
                DetailLine(label: "Created", value: "\(currentBlock.createdAt)")
                DetailLine(label: "Updated", value: "\(currentBlock.updatedAt)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle("Block")
    }
}

private struct DetailLine: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.callout)
        }
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
