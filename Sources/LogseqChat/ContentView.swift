import SwiftUI
import LogseqChatModel

struct ContentView: View {
    private static let blockListBottomID = "block-list-bottom"
    @State private var store = LogseqChatStore(call: LogseqChatCore.shared.logseq_chat_call)
    @State private var searchText = ""
    @State private var draft = ""
    @State private var composerExpanded = false
    @State private var settingsPresented = false
    @State private var baseURL = "http://127.0.0.1:8787"
    @State private var token = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                searchBar
                blockList
                composer
            }
            .background(appBackground)
            .navigationDestination(for: LogseqBlock.self) { block in
                BlockDetailView(block: block, store: store)
            }
        }
        .task {
            store.open(path: databasePath)
            await store.runRefreshLoop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.refresh()
            }
        }
        .sheet(isPresented: $settingsPresented) {
            ConnectionSettingsView(
                baseURL: $baseURL,
                token: $token,
                apply: {
                    store.configure(baseURL: baseURL, token: token)
                    settingsPresented = false
                }
            )
        }
    }

    private var databasePath: String {
        URL.documentsDirectory
            .appendingPathComponent("logseq-chat.sqlite")
            .path
    }

    private var appBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.97, green: 0.98, blue: 0.98),
                Color(red: 0.92, green: 0.95, blue: 0.96)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Logseq Chat")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("Recent blocks")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                settingsPresented = true
            } label: {
                Text("Connect")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.78))
                    .cornerRadius(22)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("button.connection")
            Button {
                store.refresh()
            } label: {
                Text(store.isRefreshing ? "Refreshing" : "Refresh")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.78))
                    .cornerRadius(22)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("button.refresh")
        }
        .padding(20)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Text("Search")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Blocks, pages, text", text: $searchText)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .onSubmit {
                    store.search(searchText)
                }
                .accessibilityIdentifier("field.search")
            if !searchText.isEmpty {
                Button("Clear") {
                    searchText = ""
                    store.search("")
                }
                .font(.subheadline)
                .accessibilityIdentifier("button.search.clear")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.82))
        .cornerRadius(22)
        .padding(.horizontal, 20)
    }

    private var blockList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let error = store.lastError {
                        ErrorBanner(error: error)
                    }
                    if store.sections.isEmpty {
                        EmptyBlocksView()
                    } else {
                        ForEach(store.sections) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(section.id)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                ForEach(section.blocks) { block in
                                    NavigationLink(value: block) {
                                        BlockRow(block: block)
                                    }
                                    .buttonStyle(.plain)
                                    .simultaneousGesture(TapGesture().onEnded {
                                        store.select(block)
                                    })
                                }
                            }
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.blockListBottomID)
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(20)
            }
            .onAppear {
                scrollToBottom(proxy)
            }
            .onChange(of: store.snapshot.revision) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: store.snapshot.blocks) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard !store.snapshot.blocks.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(Self.blockListBottomID, anchor: .bottom)
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if composerExpanded {
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Message Logseq", text: $draft, axis: .vertical)
                        .lineLimit(4)
                        .textFieldStyle(.plain)
                        .submitLabel(.send)
                        .onSubmit {
                            sendDraft()
                        }
                        .accessibilityIdentifier("field.composer")
                    Button {
                        sendDraft()
                    } label: {
                        Text("Send")
                            .fontWeight(.semibold)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray.opacity(0.18) : Color.black)
                            .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.white)
                            .cornerRadius(22)
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("button.send")
                }
            } else {
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        composerExpanded = true
                    }
                } label: {
                    HStack {
                        Text("+")
                            .font(.title2)
                            .fontWeight(.regular)
                        Text("Work in Logseq")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Text")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("button.composer.expand")
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.9))
        .cornerRadius(28)
        .shadow(color: .black.opacity(0.08), radius: 18, x: 0, y: 6)
        .padding(.horizontal, 16)
        .padding(12)
    }

    private func sendDraft() {
        store.send(draft)
        draft = ""
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            composerExpanded = false
        }
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
                    .disabled(baseURL.isEmpty || token.isEmpty)
                    .accessibilityIdentifier("button.connection.apply")
                }
            }
        }
    }
}

private struct BlockRow: View {
    let block: LogseqBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(block.title.isEmpty ? "Untitled block" : block.title)
                .font(.body)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(3)
            HStack(spacing: 8) {
                Text(block.kind)
                Text(block.timeTitle)
                Text(shortId(block.pageId))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.72))
        .cornerRadius(18)
    }

    private func shortId(_ value: String) -> String {
        String(value.prefix(8))
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
                    Text(currentBlock.title.isEmpty ? "Untitled block" : currentBlock.title)
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
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
        }
    }
}

private struct ErrorBanner: View {
    let error: LogseqChatCoreError

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(error.code)
                .font(.headline)
            Text(error.message)
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
            Text("No cached blocks")
                .font(.headline)
            Text("Refresh when the OCaml core is linked to fetch the latest Logseq blocks.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white.opacity(0.65))
        .cornerRadius(18)
    }
}
