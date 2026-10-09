import Foundation

/// Which usage window drives the compact menu-bar percentage.
enum TitleMetric: Equatable {
    case worst          // highest percentage across all windows (default)
    case active         // whichever window the API marks is_active
    case fiveHour
    case weekly
    case scoped(String) // a per-model weekly cap, e.g. "Fable"

    /// Stable string for UserDefaults persistence.
    var storageKey: String {
        switch self {
        case .worst: return "worst"
        case .active: return "active"
        case .fiveHour: return "fiveHour"
        case .weekly: return "weekly"
        case .scoped(let name): return "scoped:\(name)"
        }
    }

    init(storage: String) {
        switch storage {
        case "active": self = .active
        case "fiveHour": self = .fiveHour
        case "weekly": self = .weekly
        default:
            if storage.hasPrefix("scoped:") {
                self = .scoped(String(storage.dropFirst("scoped:".count)))
            } else {
                self = .worst
            }
        }
    }
}

enum Settings {
    /// Each provider remembers its own menu-bar metric independently, so pinning
    /// a Claude window doesn't disturb OpenAI's selection and vice versa.
    static func titleMetric(for provider: ProviderKind) -> TitleMetric {
        TitleMetric(storage: UserDefaults.standard.string(forKey: key(provider)) ?? "worst")
    }

    static func setTitleMetric(_ metric: TitleMetric, for provider: ProviderKind) {
        UserDefaults.standard.set(metric.storageKey, forKey: key(provider))
    }

    /// Bundle identifier the app shipped under through v1.0.4.
    private static let legacyDomain = "com.reaktor.aiusagebar"

    /// One-time move of preferences saved under the old bundle identifier into
    /// the current one, then delete the old preferences file. Values already
    /// set under the current identifier win. No-op once the old file is gone.
    static func migrateLegacyDefaults() {
        // A bare `swift run` binary has no bundle identifier and would pull the
        // preferences into a throwaway domain, away from the real app.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(legacyDomain).plist")
        guard FileManager.default.fileExists(atPath: plist.path) else { return }

        let defaults = UserDefaults.standard
        let legacy = defaults.persistentDomain(forName: legacyDomain) ?? [:]
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        // Delete the file directly: `removePersistentDomain` only empties the
        // domain, and the preferences daemon then writes back an empty plist.
        try? FileManager.default.removeItem(at: plist)
    }

    private static func key(_ provider: ProviderKind) -> String {
        "titleMetric.\(provider.rawValue)"
    }
}
