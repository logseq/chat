#if os(iOS)
import AppIntents
#if !WIDGET_EXTENSION
import LogseqChat
#endif

@MainActor private func openQuickAction(_ action: String) {
    #if !WIDGET_EXTENSION
    LogseqChatRuntime.shared.acceptSharedCaptureURL(URL(string: "logseqchat://\(action)")!)
    #endif
}

struct QuickAddIntent: AppIntent {
    static let title: LocalizedStringResource = "Quick Add"
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        openQuickAction("capture")
        return .result()
    }
}

struct RecordAudioIntent: AppIntent {
    static let title: LocalizedStringResource = "Record Audio"
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        openQuickAction("audio")
        return .result()
    }
}

struct OpenJournalIntent: AppIntent {
    static let title: LocalizedStringResource = "Today's Journal"
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        openQuickAction("journal")
        return .result()
    }
}

#endif
