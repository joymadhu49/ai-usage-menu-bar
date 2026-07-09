import SwiftUI

struct ContentView: View {
    @StateObject private var model = UsageViewModel()
    @State private var hostDraft = AIUsageStore.host ?? ""

    var body: some View {
        NavigationStack {
            List {
                if let snapshot = model.snapshot {
                    if let claude = snapshot.claude {
                        ProviderSection(provider: claude, icon: "rays",
                                        tint: Color(red: 0.87, green: 0.48, blue: 0.34),
                                        series: snapshot.historySeries(field: "c"),
                                        tokens: snapshot.claudeTokens, showCost: true)
                    }
                    if let codex = snapshot.codex {
                        ProviderSection(provider: codex, icon: "chevron.left.forwardslash.chevron.right",
                                        tint: .teal,
                                        series: snapshot.historySeries(field: "x"),
                                        tokens: snapshot.codexTokens, showCost: false)
                    }
                    if let grok = snapshot.grok {
                        ProviderSection(provider: grok, icon: "multiply",
                                        tint: .indigo,
                                        series: snapshot.historySeries(field: "g"),
                                        tokens: nil, showCost: false)
                    }
                    statusFooter
                } else {
                    setupSection
                }
                connectionSection
            }
            .navigationTitle("AI Usage")
            .refreshable { await model.refresh() }
            .task {
                model.discovery.start()
                await model.refresh()
            }
        }
    }

    private var statusFooter: some View {
        Section {
        } footer: {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.isLive ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(footerText)
            }
        }
    }

    private var footerText: String {
        let when = model.fetchedAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "never"
        return model.isLive ? "Live from your Mac · updated \(when)"
                            : "Showing cached data from \(when) · Mac unreachable"
    }

    private var setupSection: some View {
        Section("Waiting for your Mac") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Open **AI Usage Menu Bar** on your Mac and make sure **Settings → iPhone Sync (LAN)** is enabled, with both devices on the same Wi-Fi.")
                Text("Your Mac should appear below automatically.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.vertical, 4)
        }
    }

    private var connectionSection: some View {
        Section("Mac connection") {
            ForEach(model.discovery.foundHosts, id: \.self) { found in
                Button {
                    model.setHost(found)
                    hostDraft = found
                    Task { await model.refresh() }
                } label: {
                    HStack {
                        Label(found, systemImage: "desktopcomputer")
                        Spacer()
                        if found == model.host {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .tint(.primary)
            }

            HStack {
                TextField("Hostname or IP (e.g. MacBook.local)", text: $hostDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit {
                        model.setHost(hostDraft)
                        Task { await model.refresh() }
                    }
                if model.isLoading {
                    ProgressView()
                }
            }
        }
    }
}

private struct ProviderSection: View {
    let provider: ProviderSnapshot
    let icon: String
    let tint: Color
    let series: [(Date, Double)]
    let tokens: TokenStats?
    let showCost: Bool

    var body: some View {
        Section {
            ForEach(provider.rows) { row in
                UsageRowView(row: row)
            }
            if series.count >= 3 {
                HStack(alignment: .top, spacing: 10) {
                    Text("24h")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)
                    HistoryChart(series: series, color: tint)
                        .frame(height: 44)
                }
                .padding(.vertical, 2)
            }
            if let tokens {
                HStack(spacing: 10) {
                    Text("Tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)
                    Text(tokens.summaryLine(includeCost: showCost))
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            if let extra = provider.extra {
                Text(extra)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Label(provider.name, systemImage: icon)
                Spacer()
                if let plan = provider.plan {
                    Text(plan.uppercased())
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                }
            }
        }
    }
}

private struct UsageRowView: View {
    let row: UsageRow

    private var barColor: Color {
        switch row.severity {
        case .critical: return .red
        case .warning: return .orange
        case .ok: return .green
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(row.label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 40, maxWidth: 120, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(3, proxy.size.width * row.usedPercent / 100))
                }
            }
            .frame(height: 6)

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(Int(row.leftPercent.rounded()))% left")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                if let resets = row.resetsAt {
                    Text(resetText(resets))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func resetText(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if date.timeIntervalSinceNow < 6.5 * 86400 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
