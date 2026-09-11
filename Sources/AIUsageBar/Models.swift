import Foundation

/// Which AI provider a piece of usage data belongs to.
enum ProviderKind: String, CaseIterable {
    case claude = "Claude"
    case openai = "OpenAI"

    /// Single-character glyph used in the compact menu-bar title.
    var shortSymbol: String {
        switch self {
        case .claude: return "C"
        case .openai: return "O"
        }
    }
}

/// A single rolling-usage window (e.g. the 5-hour session window or the weekly cap).
struct UsageWindow {
    /// 0...100 percent of the window consumed.
    let usedPercent: Double
    /// When the window resets, if known.
    let resetsAt: Date?
    /// True when this is the limit currently binding usage (Claude `is_active`).
    var isActive: Bool = false
    /// Optional extra text for the gray sub-line, e.g. "$74 of $3500".
    var detail: String? = nil
}

/// A usage window that carries its own label — used for Claude's per-model
/// weekly caps (e.g. "Fable"), which live in the endpoint's `limits[]` array.
struct NamedWindow {
    let label: String
    let window: UsageWindow
}

/// The full usage snapshot for one provider at one point in time.
struct ProviderUsage {
    let provider: ProviderKind
    let planName: String?
    let fiveHour: UsageWindow?
    let weekly: UsageWindow?
    /// Per-model weekly caps (Claude only), e.g. a "Fable" window. Empty otherwise.
    var scoped: [NamedWindow] = []
    /// Non-nil when the last fetch failed. When set, the windows are the last
    /// known-good values (if any) so the UI can keep showing something useful.
    let error: String?
    let fetchedAt: Date
    /// When true, automatic refreshes skip this provider until the user clicks
    /// Refresh Now — for failures where retrying on a timer would do harm.
    var autoRefreshPaused: Bool = false

    /// Every window this provider reports, flattened — handy for "worst window" math.
    var allWindows: [UsageWindow] {
        [fiveHour, weekly].compactMap { $0 } + scoped.map { $0.window }
    }

    static func failure(_ provider: ProviderKind,
                        error: String,
                        keeping previous: ProviderUsage?,
                        at date: Date,
                        pauseAutoRefresh: Bool = false) -> ProviderUsage {
        ProviderUsage(provider: provider,
                      planName: previous?.planName,
                      fiveHour: previous?.fiveHour,
                      weekly: previous?.weekly,
                      scoped: previous?.scoped ?? [],
                      error: error,
                      fetchedAt: date,
                      autoRefreshPaused: pauseAutoRefresh)
    }
}

/// Errors surfaced by the credential readers / providers, with user-facing text.
enum UsageError: LocalizedError {
    case notAuthenticated(String)
    case unauthorized       // 401 — token present but rejected/expired
    case rateLimited        // 429
    case http(Int)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated(let hint): return "Not signed in (\(hint))"
        case .unauthorized: return "Re-auth needed"
        case .rateLimited: return "Rate limited"
        case .http(let code): return "HTTP \(code)"
        case .badResponse(let msg): return msg
        }
    }
}
