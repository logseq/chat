import SwiftUI
import WidgetKit

private struct JournalEntry: TimelineEntry {
    let date: Date
}

private struct JournalTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> JournalEntry {
        JournalEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (JournalEntry) -> Void) {
        completion(JournalEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<JournalEntry>) -> Void) {
        let now = Date.now
        let calendar = Calendar.current
        let nextDay = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: now)
        ) ?? now.addingTimeInterval(3600)
        completion(Timeline(entries: [JournalEntry(date: now)], policy: .after(nextDay)))
    }
}

private struct TodayJournalWidgetView: View {
    let entry: JournalEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LOGSEQ")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(entry.date, format: .dateTime.month(.abbreviated).day())
                .font(.title2.weight(.bold))
            Text(entry.date, format: .dateTime.weekday(.wide))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Label("Open journal", systemImage: "arrow.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "logseqchat://journal"))
    }
}

private struct CaptureWidgetView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "square.and.pencil")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.green)
            Spacer(minLength: 0)
            Text("Capture")
                .font(.title3.weight(.bold))
            Text("Add to today's journal")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "logseqchat://capture"))
    }
}

private struct TodayJournalWidget: Widget {
    let kind = "TodayJournalWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: JournalTimelineProvider()) { entry in
            TodayJournalWidgetView(entry: entry)
        }
        .configurationDisplayName("Today's Journal")
        .description("Open today's Logseq journal.")
        .supportedFamilies([.systemSmall])
    }
}

private struct CaptureWidget: Widget {
    let kind = "CaptureWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: JournalTimelineProvider()) { _ in
            CaptureWidgetView()
        }
        .configurationDisplayName("Quick Capture")
        .description("Capture a block in today's Logseq journal.")
        .supportedFamilies([.systemSmall])
    }
}

@main struct LogseqChatWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayJournalWidget()
        CaptureWidget()
    }
}
