import Foundation

/// Fetches ChatGPT (Plus/Pro) subscription usage from the undocumented
/// `chatgpt.com/backend-api/wham/usage` endpoint that Codex CLI's `/status` uses.
struct OpenAIProvider: UsageProvider {
    let kind: ProviderKind = .openai

    private let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    func fetch(previous: ProviderUsage?) async -> ProviderUsage {
        let now = Date()
        do {
            let token = try CodexCredentials.load()
            var headers = [
                "Authorization": "Bearer \(token.accessToken)",
                "User-Agent": "codex-cli",
                "Content-Type": "application/json"
            ]
            if let accountId = token.accountId {
                headers["ChatGPT-Account-Id"] = accountId
            }

            let data = try await HTTP.get(url, headers: headers)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw UsageError.badResponse("Unexpected response")
            }

            func window(_ obj: [String: Any]?) -> UsageWindow? {
                guard let obj, obj["used_percent"] != nil else { return nil }
                var reset: Date?
                if let secs = obj["reset_at"] as? Double {
                    reset = Date(timeIntervalSince1970: secs)
                } else if let secs = obj["reset_at"] as? Int {
                    reset = Date(timeIntervalSince1970: Double(secs))
                }
                return UsageWindow(usedPercent: doubleValue(obj["used_percent"]), resetsAt: reset)
            }

            // Plus/Pro: rolling windows under `rate_limit`.
            let rl = (root["rate_limit"] as? [String: Any]) ?? [:]
            let fiveHour = window(rl["primary_window"] as? [String: Any])
            let weekly = window(rl["secondary_window"] as? [String: Any])

            // Business/enterprise: `rate_limit` is null; usage is a monthly spend
            // cap under `spend_control.individual_limit` instead.
            var scoped: [NamedWindow] = []
            if let spend = spendWindow(root) {
                scoped.append(NamedWindow(label: "Spend", window: spend))
            }

            return ProviderUsage(
                provider: kind,
                planName: root["plan_type"] as? String,
                fiveHour: fiveHour,
                weekly: weekly,
                scoped: scoped,
                error: nil,
                fetchedAt: now
            )
        } catch let e as UsageError {
            return .failure(kind, error: e.errorDescription ?? "Error", keeping: previous, at: now)
        } catch {
            return .failure(kind, error: error.localizedDescription, keeping: previous, at: now)
        }
    }

    /// Build a usage window from `spend_control.individual_limit` (business plans).
    /// Dollar figures (strings) are surfaced in the window's `detail` sub-line.
    private func spendWindow(_ root: [String: Any]) -> UsageWindow? {
        guard let spend = root["spend_control"] as? [String: Any],
              let limit = spend["individual_limit"] as? [String: Any],
              limit["used_percent"] != nil else {
            return nil
        }
        var reset: Date?
        if let secs = limit["reset_at"] as? Double {
            reset = Date(timeIntervalSince1970: secs)
        } else if let secs = limit["reset_at"] as? Int {
            reset = Date(timeIntervalSince1970: Double(secs))
        }
        // `used`/`limit` arrive as strings like "73.94" / "3500".
        var detail: String?
        let used = doubleValue(limit["used"])
        let cap = doubleValue(limit["limit"])
        if cap > 0 { detail = "$\(Int(used.rounded())) of $\(Int(cap.rounded()))" }

        return UsageWindow(usedPercent: doubleValue(limit["used_percent"]),
                           resetsAt: reset,
                           detail: detail)
    }
}
