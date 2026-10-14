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
    /// Visibility only affects the compact title, not fetching or the dropdown.
    static func isShownInMenuBar(_ provider: ProviderKind) -> Bool {
        let key = "menuBarVisible.\(provider.rawValue)"
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setShownInMenuBar(_ shown: Bool, for provider: ProviderKind) {
        UserDefaults.standard.set(shown, forKey: "menuBarVisible.\(provider.rawValue)")
    }

    /// Each provider remembers its own menu-bar metric independently, so pinning
    /// a Claude window doesn't disturb OpenAI's selection and vice versa.
    static func titleMetric(for provider: ProviderKind) -> TitleMetric {
        TitleMetric(storage: UserDefaults.standard.string(forKey: key(provider)) ?? "worst")
    }

    static func setTitleMetric(_ metric: TitleMetric, for provider: ProviderKind) {
        UserDefaults.standard.set(metric.storageKey, forKey: key(provider))
    }

    private static func key(_ provider: ProviderKind) -> String {
        "titleMetric.\(provider.rawValue)"
    }
}
