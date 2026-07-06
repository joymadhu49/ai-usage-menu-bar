import WidgetKit
import SwiftUI

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
    let isLive: Bool
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, snapshot: nil, isLive: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: .now, snapshot: AIUsageStore.cachedSnapshot()?.snapshot, isLive: false))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        Task {
            let live = await UsageFetcher.fetch()
            let snapshot = live ?? AIUsageStore.cachedSnapshot()?.snapshot
            let entry = UsageEntry(date: .now, snapshot: snapshot, isLive: live != nil)
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
        }
    }
}

struct AIUsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .systemMedium:
                    MediumView(snapshot: snapshot, isLive: entry.isLive)
                default:
                    SmallView(snapshot: snapshot)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Open AI Usage to connect to your Mac")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
    }
}

private func severityColor(_ severity: Severity) -> Color {
    switch severity {
    case .critical: return .red
    case .warning: return .orange
    case .ok: return .green
    }
}

// Small: one headline row per provider — icon + % left of the primary window.
private struct SmallView: View {
    let snapshot: UsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let claude = snapshot.claude, let row = claude.rows.first {
                headline(icon: "rays", name: "Claude", row: row)
            }
            if let codex = snapshot.codex, let row = codex.rows.first {
                headline(icon: "chevron.left.forwardslash.chevron.right", name: "Codex", row: row)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func headline(icon: String, name: String, row: UsageRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(row.leftPercent.rounded()))%")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(severityColor(row.severity))
            }
            bar(for: row)
        }
    }

    private func bar(for row: UsageRow) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(severityColor(row.severity))
                    .frame(width: max(2, proxy.size.width * row.usedPercent / 100))
            }
        }
        .frame(height: 4)
    }
}

// Medium: both providers with their two main windows as labeled bars.
private struct MediumView: View {
    let snapshot: UsageSnapshot
    let isLive: Bool

    var body: some View {
        HStack(spacing: 16) {
            if let claude = snapshot.claude {
                column(icon: "rays", name: "Claude", rows: Array(claude.rows.prefix(2)))
            }
            if snapshot.claude != nil && snapshot.codex != nil {
                Divider()
            }
            if let codex = snapshot.codex {
                column(icon: "chevron.left.forwardslash.chevron.right", name: "Codex", rows: Array(codex.rows.prefix(2)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func column(icon: String, name: String, rows: [UsageRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption)
                Text(name)
                    .font(.caption.weight(.semibold))
            }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(row.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(row.leftPercent.rounded()))% left")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(severityColor(row.severity))
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.2))
                            Capsule()
                                .fill(severityColor(row.severity))
                                .frame(width: max(2, proxy.size.width * row.usedPercent / 100))
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AIUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AIUsageWidget", provider: UsageProvider()) { entry in
            AIUsageWidgetView(entry: entry)
        }
        .configurationDisplayName("AI Usage")
        .description("Claude Code and Codex usage from your Mac.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct AIUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        AIUsageWidget()
    }
}
