import SwiftUI
import LogseqChatModel

/// Full-screen search backed by the per-graph sqlite search index. Lists
/// matching pages and blocks; block results include their breadcrumb path.
struct NodeSearchView: View {
    let store: LogseqChatStore
    let close: () -> Void
    let open: (LogseqSearchHit) -> Void

    @Binding private var query: String
    #if !SKIP && os(iOS)
    @State private var nativeSearchPresented = true
    @FocusState private var nativeSearchFocused: Bool
    #endif
    @FocusState private var queryFocused: Bool

    init(
        store: LogseqChatStore,
        query: Binding<String>,
        close: @escaping () -> Void,
        open: @escaping (LogseqSearchHit) -> Void
    ) {
        self.store = store
        _query = query
        self.close = close
        self.open = open
    }

    private var results: [LogseqSearchHit] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return store.snapshot.searchResults ?? []
    }

    private var pageResults: [LogseqSearchHit] {
        results.filter(\.isPage)
    }

    private var blockResults: [LogseqSearchHit] {
        results.filter { !$0.isPage }
    }

    var body: some View {
        Group {
            #if !SKIP && os(iOS)
            if #available(iOS 26.0, *) {
                nativeSearch
            } else {
                fallbackSearch
            }
            #else
            fallbackSearch
            #endif
        }
        .onAppear {
            #if SKIP
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                queryFocused = true
            }
            #endif
        }
        .accessibilityIdentifier("screen.search")
    }

    #if !SKIP && os(iOS)
    @available(iOS 26.0, *)
    private var nativeSearch: some View {
        resultsList
            .searchable(
                text: $query,
                isPresented: $nativeSearchPresented,
                placement: .toolbar,
                prompt: "Search pages and blocks"
            )
            .searchFocused($nativeSearchFocused)
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .toolbarVisibility(.hidden, for: .navigationBar)
            .toolbar {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    closeButton
                }
            }
            .onChange(of: query) { _, newQuery in
                store.searchNodes(newQuery)
            }
            .onAppear {
                nativeSearchPresented = true
                DispatchQueue.main.async {
                    nativeSearchFocused = true
                }
            }
            .onScrollPhaseChange { _, newPhase in
                if newPhase == .tracking || newPhase == .interacting {
                    nativeSearchFocused = false
                }
            }
    }
    #endif

    private var fallbackSearch: some View {
        VStack(spacing: 0) {
            resultsList
            searchField
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image("search", bundle: .module)
                .frame(width: 18, height: 18)
            TextField("Search pages and blocks", text: $query)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .focused($queryFocused)
                .onChange(of: query) { _, newQuery in
                    store.searchNodes(newQuery)
                }
                .accessibilityIdentifier("field.search")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image("close", bundle: .module)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("button.search.clear")
            }
            closeButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .platformGlassContainer()
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var closeButton: some View {
        Button(action: exitSearch) {
            Image("close", bundle: .module)
                .frame(width: 20, height: 20)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close search")
        .accessibilityIdentifier("button.search.close")
    }

    private func exitSearch() {
        queryFocused = false
        #if !SKIP && os(iOS)
        nativeSearchFocused = false
        nativeSearchPresented = false
        DispatchQueue.main.async {
            close()
        }
        #else
        close()
        #endif
    }

    @ViewBuilder private var resultsList: some View {
        if results.isEmpty {
            emptyState
        } else {
            List {
                if !pageResults.isEmpty {
                    Section("Pages") {
                        ForEach(pageResults) { hit in
                            resultRow(hit)
                        }
                    }
                }
                if !blockResults.isEmpty {
                    Section("Blocks") {
                        ForEach(blockResults) { hit in
                            resultRow(hit)
                        }
                    }
                }
            }
            #if !SKIP
            .listStyle(.plain)
            .scrollDismissesKeyboard(.interactively)
            #endif
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(verbatim: "Search your graph")
                    .foregroundStyle(.secondary)
            } else {
                Text(verbatim: "No results")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultRow(_ hit: LogseqSearchHit) -> some View {
        Button {
            open(hit)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: hit.isPage ? "doc.text" : "circle.fill")
                    .font(hit.isPage ? .body : .system(size: 6))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: hit.title)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                    if let breadcrumb = breadcrumbText(hit) {
                        Text(verbatim: breadcrumb)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .platformRectangularHitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("search.result.\(hit.uuid)")
    }

    private func breadcrumbText(_ hit: LogseqSearchHit) -> String? {
        guard !hit.isPage else { return nil }
        var titles = hit.breadcrumbs.map(\.title)
        if titles.isEmpty, let page = hit.page {
            titles = [page.title]
        }
        guard !titles.isEmpty else { return nil }
        return titles.joined(separator: " › ")
    }
}
