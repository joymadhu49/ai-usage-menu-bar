import Foundation
import WidgetKit

// Discovers Macs running the menu-bar app via Bonjour (_aiusage._tcp).
final class MacDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published var foundHosts: [String] = []

    private let browser = NetServiceBrowser()
    private var pending: [NetService] = []

    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: "_aiusage._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        pending.removeAll()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        pending.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard var host = sender.hostName else { return }
        if host.hasSuffix(".") {
            host.removeLast()
        }
        DispatchQueue.main.async {
            if !self.foundHosts.contains(host) {
                self.foundHosts.append(host)
            }
            // Auto-adopt the first discovered Mac when nothing is configured.
            if (AIUsageStore.host ?? "").isEmpty {
                AIUsageStore.host = host
            }
        }
    }
}

@MainActor
final class UsageViewModel: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var fetchedAt: Date?
    @Published var isLive = false
    @Published var isLoading = false
    @Published var host: String = AIUsageStore.host ?? ""

    let discovery = MacDiscovery()

    init() {
        if let cached = AIUsageStore.cachedSnapshot() {
            snapshot = cached.snapshot
            fetchedAt = cached.fetchedAt
        }
    }

    func setHost(_ newHost: String) {
        let trimmed = newHost.trimmingCharacters(in: .whitespacesAndNewlines)
        host = trimmed
        AIUsageStore.host = trimmed
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        if let live = await UsageFetcher.fetch() {
            snapshot = live
            fetchedAt = Date()
            isLive = true
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        isLive = false
        if snapshot == nil, let cached = AIUsageStore.cachedSnapshot() {
            snapshot = cached.snapshot
            fetchedAt = cached.fetchedAt
        }
    }
}
