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

    private static func key(_ provider: ProviderKind) -> String {
        "titleMetric.\(provider.rawValue)"
    }
}
