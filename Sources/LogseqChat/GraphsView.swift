import SwiftUI
import LogseqChatModel

struct GraphsView: View {
    let graphs: [LogseqGraph]
    let databasePath: String
    let refresh: () -> Void
    let open: (LogseqGraph) -> Void
    let deleteGraph: (LogseqGraph) async throws -> Void

    @State private var pendingDeletion: LogseqGraph?
    @State private var deletingGraphID: String?
    @State private var storageRevision = 0
    @State private var feedbackRevision = 0
    @State private var deletionError: String?

    private var localGraphs: [LogseqGraph] {
        _ = storageRevision
        return graphs.filter(isDownloaded)
    }

    private var remoteGraphs: [LogseqGraph] {
        _ = storageRevision
        return graphs.filter { !isDownloaded($0) }
    }

    var body: some View {
        graphsContent
    }

    private var graphsContent: some View {
            List {
                Button {
                    feedbackRevision += 1
                    refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("button.graphs.refresh")

                Section("Local graphs:") {
                    if localGraphs.isEmpty {
                        Text(verbatim: "No local graphs")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(localGraphs) { graph in
                            localGraphRow(graph)
                        }
                    }
                }

                if !remoteGraphs.isEmpty {
                    Section("Remote graphs:") {
                        ForEach(remoteGraphs) { graph in
                            remoteGraphRow(graph)
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete local graph",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Confirm", role: .destructive) {
                    guard let graph = pendingDeletion else { return }
                    pendingDeletion = nil
                    deletingGraphID = graph.id
                    feedbackRevision += 1
                    Task {
                        do {
                            try await deleteGraph(graph)
                            storageRevision += 1
                        } catch {
                            deletionError = error.localizedDescription
                        }
                        deletingGraphID = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingDeletion = nil
                }
            } message: {
                if let graph = pendingDeletion {
                    Text(verbatim: "Are you sure you want to permanently delete the graph \"\(graph.name)\" from Logseq?\n\n⚠️ Notice that we can't recover this graph after being deleted. Make sure you have backups before deleting it.")
                }
            }
            .alert("Delete local graph", isPresented: Binding(
                get: { deletionError != nil },
                set: { if !$0 { deletionError = nil } }
            )) {
                Button("OK") { deletionError = nil }
            } message: {
                Text(verbatim: deletionError ?? "")
            }
            .sensoryFeedback(.impact(weight: .light), trigger: feedbackRevision)
        .accessibilityIdentifier("screen.graphs")
    }

    private func isDownloaded(_ graph: LogseqGraph) -> Bool {
        LogseqGraphLocalStorage.isDownloaded(databasePath: databasePath, graphID: graph.id)
    }

    private func localGraphRow(_ graph: LogseqGraph) -> some View {
        HStack(spacing: 8) {
            graphButton(graph, systemImage: "cylinder.split.1x2")
            Menu {
                Button("Delete local graph", role: .destructive) {
                    pendingDeletion = graph
                    feedbackRevision += 1
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
            }
            .accessibilityIdentifier("button.graph.delete.\(graph.id)")
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete local graph", role: .destructive) {
                pendingDeletion = graph
                feedbackRevision += 1
            }
        }
        .disabled(deletingGraphID == graph.id)
    }

    private func remoteGraphRow(_ graph: LogseqGraph) -> some View {
        graphButton(graph, systemImage: graph.isEncrypted ? "lock" : "icloud")
            .disabled(!graph.isReady)
    }

    private func graphButton(_ graph: LogseqGraph, systemImage: String) -> some View {
        Button {
            feedbackRevision += 1
            open(graph)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: graph.name)
                        .foregroundStyle(.primary)
                    if !graph.isReady {
                        Text(verbatim: "Preparing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if deletingGraphID == graph.id {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("graph.\(graph.id)")
    }
}
