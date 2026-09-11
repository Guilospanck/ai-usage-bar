import Foundation

/// Owns the set of providers, the latest snapshot per provider, and the polling
/// loop. Runs on the main actor so the UI can read `latest` without locking.
@MainActor
final class UsageStore {
    private let providers: [UsageProvider]
    private(set) var latest: [ProviderKind: ProviderUsage] = [:]
    private(set) var isRefreshing = false

    /// Called on the main actor whenever `latest` changes.
    var onUpdate: (() -> Void)?

    /// Seconds between automatic refreshes.
    var refreshInterval: TimeInterval = 120

    private var loopTask: Task<Void, Never>?

    init(providers: [UsageProvider]) {
        self.providers = providers
    }

    func start() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                let interval = self.refreshInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Refresh providers concurrently, then publish once. Automatic refreshes
    /// skip providers whose auto-refresh is paused; a `manual` refresh (Refresh
    /// Now) retries every provider.
    func refresh(manual: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        onUpdate?()

        let snapshot = latest
        let due = providers.filter { manual || snapshot[$0.kind]?.autoRefreshPaused != true }
        let results = await withTaskGroup(of: ProviderUsage.self) { group -> [ProviderUsage] in
            for provider in due {
                let previous = snapshot[provider.kind]
                group.addTask { await provider.fetch(previous: previous) }
            }
            var out: [ProviderUsage] = []
            for await r in group { out.append(r) }
            return out
        }

        for r in results { latest[r.provider] = r }
        isRefreshing = false
        onUpdate?()
    }

    /// Snapshots ordered by ProviderKind's declaration order for stable display.
    var ordered: [ProviderUsage] {
        ProviderKind.allCases.compactMap { latest[$0] }
    }
}
