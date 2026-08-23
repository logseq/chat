import SwiftUI
import LogseqChatModel

/// Dedicated search page backed by the per-graph sqlite search index. Lists
/// matching pages and blocks; block results include their breadcrumb path.
struct NodeSearchView: View {
    let store: LogseqChatStore
    let dismissAfterOpen: Bool
    let open: (LogseqSearchHit) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var queryFocused: Bool

    init(
        store: LogseqChatStore,
        dismissAfterOpen: Bool = true,
        open: @escaping (LogseqSearchHit) -> Void
    ) {
        self.store = store
        self.dismissAfterOpen = dismissAfterOpen
        self.open = open
    }

    private var results: [LogseqSearchHit] {
        store.snapshot.searchResults ?? []
    }

    private var pageResults: [LogseqSearchHit] {
        results.filter(\.isPage)
    }

    private var blockResults: [LogseqSearchHit] {
        results.filter { !$0.isPage }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            resultsList
        }
        .onAppear {
            store.searchNodes(query)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                queryFocused = true
            }
        }
        .accessibilityIdentifier("screen.search")
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
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
                    store.searchNodes("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("button.search.clear")
            }
            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("button.search.cancel")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .platformGlassContainer()
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
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
            if dismissAfterOpen { dismiss() }
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
