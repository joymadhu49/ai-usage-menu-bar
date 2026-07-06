import WidgetKit
import SwiftUI

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
    let fetchedAt: Date?
    let isLive: Bool
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, snapshot: nil, fetchedAt: nil, isLive: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        let cached = AIUsageStore.cachedSnapshot()
        completion(UsageEntry(date: .now, snapshot: cached?.snapshot, fetchedAt: cached?.fetchedAt, isLive: false))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        Task {
            let live = await UsageFetcher.fetch()
            let cached = live == nil ? AIUsageStore.cachedSnapshot() : nil
            let entry = UsageEntry(date: .now,
                                   snapshot: live ?? cached?.snapshot,
                                   fetchedAt: live != nil ? Date() : cached?.fetchedAt,
                                   isLive: live != nil)
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
        }
    }
}

// MARK: - Shared styling

private enum ProviderStyle {
    static let claudeIcon = "rays"
    static let codexIcon = "chevron.left.forwardslash.chevron.right"
    static let claudeTint = Color(red: 0.87, green: 0.48, blue: 0.34)
}

private func severityColor(_ severity: Severity) -> Color {
    switch severity {
    case .critical: return .red
    case .warning: return .orange
    case .ok: return .green
    }
}

private func resetText(_ date: Date?) -> String? {
    guard let date else { return nil }
    if Calendar.current.isDateInToday(date) {
        return date.formatted(date: .omitted, time: .shortened)
    }
    return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
}

private struct BarView: View {
    let row: UsageRow

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(severityColor(row.severity))
                    .frame(width: max(3, proxy.size.width * row.usedPercent / 100))
            }
        }
        .frame(height: 5)
    }
}

private struct EmptyStateView: View {
    var body: some View {
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

// MARK: - Main widget views

struct AIUsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .accessoryInline:
                    InlineView(snapshot: snapshot)
                case .accessoryRectangular:
                    RectangularView(snapshot: snapshot)
                case .systemMedium:
                    MediumView(snapshot: snapshot, entry: entry)
                case .systemLarge:
                    LargeView(snapshot: snapshot, entry: entry)
                default:
                    SmallView(snapshot: snapshot)
                }
            } else if family == .accessoryInline {
                Text("AI Usage: open app")
            } else {
                EmptyStateView()
            }
        }
        .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
    }
}

private struct InlineView: View {
    let snapshot: UsageSnapshot

    var body: some View {
        let claude = snapshot.claude?.rows.first.map { "\(Int($0.leftPercent.rounded()))%" } ?? "--"
        let codex = snapshot.codex?.rows.first.map { "\(Int($0.leftPercent.rounded()))%" } ?? "--"
        Text("Claude \(claude) · Codex \(codex)")
    }
}

private struct RectangularView: View {
    let snapshot: UsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let row = snapshot.claude?.rows.first {
                line(icon: ProviderStyle.claudeIcon, name: "Claude", row: row)
            }
            if let row = snapshot.codex?.rows.first {
                line(icon: ProviderStyle.codexIcon, name: "Codex", row: row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func line(icon: String, name: String, row: UsageRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2)
                Text(name).font(.caption2.weight(.medium))
                Spacer()
                Text("\(Int(row.leftPercent.rounded()))%")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
            BarView(row: row)
        }
    }
}

private struct SmallView: View {
    let snapshot: UsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let claude = snapshot.claude, let row = claude.rows.first {
                headline(icon: ProviderStyle.claudeIcon, tint: ProviderStyle.claudeTint, name: "Claude", row: row)
            }
            if let codex = snapshot.codex, let row = codex.rows.first {
                headline(icon: ProviderStyle.codexIcon, tint: .secondary, name: "Codex", row: row)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func headline(icon: String, tint: Color, name: String, row: UsageRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                Text(name)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(row.leftPercent.rounded()))%")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(severityColor(row.severity))
            }
            BarView(row: row)
            if let reset = resetText(row.resetsAt) {
                Text("resets \(reset)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct ProviderHeader: View {
    let icon: String
    let tint: Color
    let name: String
    let plan: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(name)
                .font(.caption.weight(.semibold))
            Spacer()
            if let plan {
                Text(plan.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct UsageSlotRow: View {
    let row: UsageRow
    let showReset: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                if showReset, let reset = resetText(row.resetsAt) {
                    Text("resets \(reset)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text("\(Int(row.leftPercent.rounded()))% left")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(severityColor(row.severity))
            }
            BarView(row: row)
        }
    }
}

// A column with a fixed number of row slots so side-by-side providers stay
// vertically aligned even when one has fewer windows.
private struct ProviderColumn: View {
    let icon: String
    let tint: Color
    let name: String
    let plan: String?
    let rows: [UsageRow]
    let slots: Int
    let showResets: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProviderHeader(icon: icon, tint: tint, name: name, plan: plan)
            ForEach(0..<slots, id: \.self) { index in
                if index < rows.count {
                    UsageSlotRow(row: rows[index], showReset: showResets)
                        .frame(height: 30, alignment: .top)
                } else {
                    Color.clear.frame(height: 30)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UpdatedFooter: View {
    let entry: UsageEntry

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(entry.isLive ? Color.green : Color.orange)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private var text: String {
        let when = (entry.fetchedAt ?? entry.date).formatted(date: .omitted, time: .shortened)
        return entry.isLive ? "Live · \(when)" : "Cached · \(when)"
    }
}

private struct MediumView: View {
    let snapshot: UsageSnapshot
    let entry: UsageEntry

    var body: some View {
        // Both columns share the same slot count so their rows line up.
        let slots = min(2, max(snapshot.claude?.rows.count ?? 0, snapshot.codex?.rows.count ?? 0))
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 14) {
                if let claude = snapshot.claude {
                    ProviderColumn(icon: ProviderStyle.claudeIcon, tint: ProviderStyle.claudeTint,
                                   name: "Claude", plan: claude.plan,
                                   rows: Array(claude.rows.prefix(2)), slots: slots, showResets: false)
                }
                if snapshot.claude != nil && snapshot.codex != nil {
                    Divider()
                }
                if let codex = snapshot.codex {
                    ProviderColumn(icon: ProviderStyle.codexIcon, tint: .secondary,
                                   name: "Codex", plan: codex.plan,
                                   rows: Array(codex.rows.prefix(2)), slots: slots, showResets: false)
                }
            }
            Spacer(minLength: 0)
            UpdatedFooter(entry: entry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// Large: full rows with reset times plus a 24h activity chart per provider.
private struct LargeView: View {
    let snapshot: UsageSnapshot
    let entry: UsageEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let claude = snapshot.claude {
                providerBlock(provider: claude, icon: ProviderStyle.claudeIcon,
                              tint: ProviderStyle.claudeTint, name: "Claude Code",
                              series: snapshot.historySeries(claude: true))
            }
            Divider()
            if let codex = snapshot.codex {
                providerBlock(provider: codex, icon: ProviderStyle.codexIcon,
                              tint: .secondary, name: "Codex",
                              series: snapshot.historySeries(claude: false))
            }
            Spacer(minLength: 0)
            UpdatedFooter(entry: entry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func providerBlock(provider: ProviderSnapshot, icon: String, tint: Color,
                               name: String, series: [(Date, Double)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProviderHeader(icon: icon, tint: tint, name: name, plan: provider.plan)
            ForEach(provider.rows) { row in
                UsageSlotRow(row: row, showReset: true)
            }
            if series.count >= 3 {
                HStack(alignment: .top, spacing: 6) {
                    Text("24h")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    HistoryChart(series: series, color: tint == .secondary ? .teal : tint)
                        .frame(height: 30)
                }
            }
            if let extra = provider.extra {
                Text(extra)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Provider ring widgets (home small + lock screen circular)

private struct RingView: View {
    @Environment(\.widgetFamily) private var family
    let name: String
    let icon: String
    let row: UsageRow?

    private var left: Double { row?.leftPercent ?? 0 }
    private var color: Color { row.map { severityColor($0.severity) } ?? .secondary }
    private var isSmall: Bool { family == .systemSmall }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.22), lineWidth: isSmall ? 10 : 5)
            Circle()
                .trim(from: 0, to: CGFloat(max(0.02, left / 100)))
                .stroke(color, style: StrokeStyle(lineWidth: isSmall ? 10 : 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: isSmall ? 3 : 0) {
                Image(systemName: icon)
                    .font(isSmall ? .callout : .system(size: 9))
                    .foregroundStyle(.secondary)
                Text(row != nil ? "\(Int(left.rounded()))%" : "--")
                    .font(isSmall ? .title2.weight(.semibold) : .caption2.weight(.semibold))
                    .monospacedDigit()
                if isSmall {
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(isSmall ? 12 : 2)
        .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
    }
}

struct ClaudeRingView: View {
    let entry: UsageEntry
    var body: some View {
        RingView(name: "Claude", icon: ProviderStyle.claudeIcon, row: entry.snapshot?.claude?.rows.first)
    }
}

struct CodexRingView: View {
    let entry: UsageEntry
    var body: some View {
        RingView(name: "Codex", icon: ProviderStyle.codexIcon, row: entry.snapshot?.codex?.rows.first)
    }
}

// MARK: - Widget declarations

struct AIUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AIUsageWidget", provider: UsageProvider()) { entry in
            AIUsageWidgetView(entry: entry)
        }
        .configurationDisplayName("AI Usage")
        .description("Claude Code and Codex usage from your Mac.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryInline, .accessoryRectangular])
    }
}

struct ClaudeRingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AIUsageClaudeRing", provider: UsageProvider()) { entry in
            ClaudeRingView(entry: entry)
        }
        .configurationDisplayName("Claude Ring")
        .description("Claude Code session % left at a glance.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

struct CodexRingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AIUsageCodexRing", provider: UsageProvider()) { entry in
            CodexRingView(entry: entry)
        }
        .configurationDisplayName("Codex Ring")
        .description("Codex % left at a glance.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

@main
struct AIUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        AIUsageWidget()
        ClaudeRingWidget()
        CodexRingWidget()
    }
}
