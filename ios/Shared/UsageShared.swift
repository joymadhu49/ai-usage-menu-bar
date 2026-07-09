import Foundation

// Shared store between the app and the widget. Falls back to standard
// defaults when the app group is unavailable (e.g. signing without groups).
enum AIUsageStore {
    static let appGroup = "group.com.local.aiusage"
    static let port = 8737
    static let hostKey = "macHost"
    static let snapshotKey = "lastSnapshotData"
    static let snapshotDateKey = "lastSnapshotDate"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    static var host: String? {
        get { defaults.string(forKey: hostKey) }
        set { defaults.set(newValue, forKey: hostKey) }
    }

    static func cacheSnapshot(_ data: Data) {
        defaults.set(data, forKey: snapshotKey)
        defaults.set(Date().timeIntervalSince1970, forKey: snapshotDateKey)
    }

    static func cachedSnapshot() -> (snapshot: UsageSnapshot, fetchedAt: Date)? {
        guard let data = defaults.data(forKey: snapshotKey),
              let snapshot = UsageSnapshot.parse(data) else { return nil }
        let at = defaults.double(forKey: snapshotDateKey)
        return (snapshot, at > 0 ? Date(timeIntervalSince1970: at) : Date())
    }
}

enum Severity {
    case ok, warning, critical

    init(usedPercent: Double) {
        if usedPercent >= 90 { self = .critical }
        else if usedPercent >= 75 { self = .warning }
        else { self = .ok }
    }
}

struct UsageRow: Identifiable {
    let id = UUID()
    let label: String
    let usedPercent: Double
    let resetsAt: Date?

    var leftPercent: Double { max(0, min(100, 100 - usedPercent)) }
    var severity: Severity { Severity(usedPercent: usedPercent) }
}

struct ProviderSnapshot {
    let name: String
    let plan: String?
    let rows: [UsageRow]
    let extra: String?
}

// One point of the Mac's rolling 24h sample history.
struct HistoryPoint {
    let date: Date
    let claudeUsed: Double?
    let codexUsed: Double?
    let grokUsed: Double?
}

// Token usage aggregates scanned from the Mac's local session logs.
struct TokenStats {
    let todayTokens: Double
    let todayCost: Double
    let totalTokens: Double
    let totalCost: Double

    static func parse(_ dict: [String: Any]?) -> TokenStats? {
        guard let dict, let total = (dict["total"] as? NSNumber)?.doubleValue, total > 0 else { return nil }
        return TokenStats(todayTokens: (dict["today"] as? NSNumber)?.doubleValue ?? 0,
                          todayCost: (dict["today_cost"] as? NSNumber)?.doubleValue ?? 0,
                          totalTokens: total,
                          totalCost: (dict["total_cost"] as? NSNumber)?.doubleValue ?? 0)
    }

    static func compactCount(_ value: Double) -> String {
        if value >= 1e9 { return String(format: "%.2fB", value / 1e9) }
        if value >= 1e6 { return String(format: "%.1fM", value / 1e6) }
        if value >= 1e3 { return String(format: "%.1fK", value / 1e3) }
        return String(format: "%.0f", value)
    }

    static func compactCost(_ value: Double) -> String {
        if value >= 1000 { return String(format: "~$%.1fK", value / 1000) }
        if value >= 100 { return String(format: "~$%.0f", value) }
        return String(format: "~$%.2f", value)
    }

    // "30.0M today (~$68.98) · 2.02B total (~$5.0K)"
    func summaryLine(includeCost: Bool) -> String {
        var line = "\(Self.compactCount(todayTokens)) today"
        if includeCost && todayCost > 0.005 {
            line += " (\(Self.compactCost(todayCost)))"
        }
        line += " · \(Self.compactCount(totalTokens)) total"
        if includeCost && totalCost > 0.005 {
            line += " (\(Self.compactCost(totalCost)))"
        }
        return line
    }
}

// Parses the JSON served by the Mac menu-bar app's LAN sync server. The
// provider dictionaries are the app's internal state dictionaries verbatim.
struct UsageSnapshot {
    let generatedAt: Date
    let claude: ProviderSnapshot?
    let codex: ProviderSnapshot?
    let grok: ProviderSnapshot?
    let history: [HistoryPoint]
    let claudeTokens: TokenStats?
    let codexTokens: TokenStats?

    // (date, used%) series for one provider field ("c"/"x"/"g"), oldest first.
    func historySeries(field: String) -> [(Date, Double)] {
        history.compactMap { point in
            let value: Double?
            switch field {
            case "c": value = point.claudeUsed
            case "x": value = point.codexUsed
            default: value = point.grokUsed
            }
            guard let value else { return nil }
            return (point.date, value)
        }
    }

    static func parse(_ data: Data) -> UsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let generated = (root["generated_at"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
        let claude = provider(from: root["claude"] as? [String: Any],
                              name: "Claude Code", defaultPrimary: "5h", defaultSecondary: "7d", scoped: true)
        let codex = provider(from: root["codex"] as? [String: Any],
                             name: "Codex", defaultPrimary: "5h", defaultSecondary: "7d", scoped: true)
        let grok = provider(from: root["grok"] as? [String: Any],
                            name: "Grok", defaultPrimary: "7d", defaultSecondary: "7d", scoped: false)
        if claude == nil && codex == nil && grok == nil {
            return nil
        }

        var history: [HistoryPoint] = []
        if let entries = root["history"] as? [[String: Any]] {
            for entry in entries {
                guard let t = (entry["t"] as? NSNumber)?.doubleValue else { continue }
                let c = (entry["c"] as? NSNumber)?.doubleValue
                let x = (entry["x"] as? NSNumber)?.doubleValue
                let g = (entry["g"] as? NSNumber)?.doubleValue
                history.append(HistoryPoint(date: Date(timeIntervalSince1970: t),
                                            claudeUsed: (c ?? -1) >= 0 ? c : nil,
                                            codexUsed: (x ?? -1) >= 0 ? x : nil,
                                            grokUsed: (g ?? -1) >= 0 ? g : nil))
            }
            history.sort { $0.date < $1.date }
        }

        let tokens = root["tokens"] as? [String: Any]
        return UsageSnapshot(generatedAt: generated, claude: claude, codex: codex, grok: grok, history: history,
                             claudeTokens: TokenStats.parse(tokens?["claude"] as? [String: Any]),
                             codexTokens: TokenStats.parse(tokens?["codex"] as? [String: Any]))
    }

    private static func provider(from state: [String: Any]?,
                                 name: String,
                                 defaultPrimary: String,
                                 defaultSecondary: String,
                                 scoped: Bool) -> ProviderSnapshot? {
        guard let state, !state.isEmpty else { return nil }
        func num(_ key: String, in dict: [String: Any]) -> Double? {
            (dict[key] as? NSNumber)?.doubleValue
        }
        func str(_ key: String, in dict: [String: Any]) -> String? {
            dict[key] as? String
        }

        var rows: [UsageRow] = []
        let primaryLabel = str("primary_window_label", in: state) ?? defaultPrimary
        let secondaryLabel = str("secondary_window_label", in: state) ?? defaultSecondary
        if let used = num("primary_used_percent", in: state) {
            rows.append(UsageRow(label: primaryLabel, usedPercent: used,
                                 resetsAt: num("primary_resets_at", in: state).map(Date.init(timeIntervalSince1970:))))
        }
        if let used = num("secondary_used_percent", in: state) {
            rows.append(UsageRow(label: secondaryLabel, usedPercent: used,
                                 resetsAt: num("secondary_resets_at", in: state).map(Date.init(timeIntervalSince1970:))))
        }
        if scoped, let scopedRows = state["scoped_limits"] as? [[String: Any]] {
            for row in scopedRows {
                guard let label = str("label", in: row), let used = num("used_percent", in: row) else { continue }
                rows.append(UsageRow(label: label, usedPercent: used,
                                     resetsAt: num("resets_at", in: row).map(Date.init(timeIntervalSince1970:))))
            }
        }
        if rows.isEmpty {
            return nil
        }

        var plan = str("plan_summary", in: state)
        if let p = plan, p.hasPrefix("Plan: ") {
            plan = String(p.dropFirst(6))
        }
        return ProviderSnapshot(name: name, plan: plan, rows: rows, extra: str("extra_summary", in: state))
    }
}

enum UsageFetcher {
    static func url() -> URL? {
        guard let host = AIUsageStore.host, !host.isEmpty else { return nil }
        return URL(string: "http://\(host):\(AIUsageStore.port)/usage.json")
    }

    // Fetches from the Mac and caches the raw payload for the widget.
    static func fetch() async -> UsageSnapshot? {
        guard let url = url() else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let snapshot = UsageSnapshot.parse(data) else {
            return nil
        }
        AIUsageStore.cacheSnapshot(data)
        return snapshot
    }
}
