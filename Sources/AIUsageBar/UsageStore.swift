import Foundation

/// Owns provider snapshots and polling. Disabled providers never start a fetch.
@MainActor
final class UsageStore {
    private let providers: [UsageProvider]
    private(set) var latest: [ProviderKind: ProviderUsage] = [:]
    var isRefreshing: Bool { !inFlight.isEmpty }
    var hasTrackedProviders: Bool { providers.contains { Settings.isTracked($0.kind) } }

    var onUpdate: (() -> Void)?
    var refreshInterval: TimeInterval = 120

    private struct Fetch {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var inFlight: [ProviderKind: Fetch] = [:]
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
                guard !Task.isCancelled else { break }
                try? await Task.sleep(nanoseconds: UInt64(self.refreshInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        for fetch in inFlight.values { fetch.task.cancel() }
        inFlight.removeAll()
    }

    func setTracked(_ tracked: Bool, for kind: ProviderKind) {
        Settings.setTracked(tracked, for: kind)
        if tracked {
            if let provider = providers.first(where: { $0.kind == kind }) {
                launch(provider)
            }
        } else {
            inFlight.removeValue(forKey: kind)?.task.cancel()
            latest.removeValue(forKey: kind)
        }
        onUpdate?()
    }

    /// Manual refresh retries paused providers, but never disabled ones.
    func refresh(manual: Bool = false) async {
        guard !Task.isCancelled else { return }
        for provider in providers where Settings.isTracked(provider.kind) {
            if manual || latest[provider.kind]?.autoRefreshPaused != true {
                launch(provider)
            }
        }
        onUpdate?()
        let tasks = inFlight.values.map(\.task)
        for task in tasks { await task.value }
    }

    private func launch(_ provider: UsageProvider) {
        let kind = provider.kind
        guard Settings.isTracked(kind), inFlight[kind] == nil else { return }
        let id = UUID()
        let previous = latest[kind]
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let result = await provider.fetch(previous: previous)
            guard let self, !Task.isCancelled,
                  Settings.isTracked(kind), self.inFlight[kind]?.id == id else { return }
            self.latest[kind] = result
            self.inFlight.removeValue(forKey: kind)
            self.onUpdate?()
        }
        inFlight[kind] = Fetch(id: id, task: task)
    }

    var ordered: [ProviderUsage] {
        ProviderKind.allCases.filter { Settings.isTracked($0) }.compactMap { latest[$0] }
    }
}
