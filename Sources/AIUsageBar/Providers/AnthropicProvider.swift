import Foundation

/// Fetches Claude (Pro/Max) subscription usage from the undocumented
/// `api.anthropic.com/api/oauth/usage` endpoint that Claude Code itself uses.
struct AnthropicProvider: UsageProvider {
    let kind: ProviderKind = .claude

    private let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    func fetch(previous: ProviderUsage?) async -> ProviderUsage {
        let now = Date()
        do {
            let token = try await ClaudeCredentials.load()
            let data = try await HTTP.get(url, headers: [
                "Authorization": "Bearer \(token.accessToken)",
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": "claude-code/2.1.183",
                "Content-Type": "application/json"
            ])

            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw UsageError.badResponse("Unexpected response")
            }

            // Preferred source: the structured `limits` array, which carries the
            // session window, the all-model weekly cap, and per-model weekly caps
            // (e.g. Fable) via `scope.model.display_name`.
            if let limits = root["limits"] as? [[String: Any]], !limits.isEmpty {
                var fiveHour: UsageWindow?
                var weekly: UsageWindow?
                var scoped: [NamedWindow] = []

                for entry in limits {
                    guard let w = limitWindow(entry) else { continue }
                    switch entry["kind"] as? String {
                    case "session":
                        fiveHour = w
                    case "weekly_all":
                        weekly = w
                    case "weekly_scoped":
                        let name = modelName(entry) ?? "scoped"
                        scoped.append(NamedWindow(label: "Weekly · \(name)", window: w))
                    default:
                        // Unknown kind: keep it visible rather than dropping it.
                        let name = modelName(entry) ?? (entry["kind"] as? String)?.capitalized ?? "Other"
                        scoped.append(NamedWindow(label: "Weekly · \(name)", window: w))
                    }
                }

                return ProviderUsage(provider: kind,
                                     planName: token.subscriptionType,
                                     fiveHour: fiveHour,
                                     weekly: weekly,
                                     scoped: scoped,
                                     error: nil,
                                     fetchedAt: now)
            }

            // Fallback: legacy top-level objects. `five_hour` is the sanity check.
            guard let fiveHourObj = root["five_hour"] as? [String: Any] else {
                throw UsageError.badResponse("Missing five_hour / limits")
            }
            func legacyWindow(_ obj: [String: Any]?) -> UsageWindow? {
                guard let obj else { return nil }
                return UsageWindow(usedPercent: doubleValue(obj["utilization"]),
                                   resetsAt: parseISO8601(obj["resets_at"] as? String))
            }
            return ProviderUsage(
                provider: kind,
                planName: token.subscriptionType,
                fiveHour: legacyWindow(fiveHourObj),
                weekly: legacyWindow(root["seven_day"] as? [String: Any]),
                error: nil,
                fetchedAt: now
            )
        } catch let e as ClaudeCredentials.KeychainError {
            return .failure(kind, error: e.errorDescription ?? "Error", keeping: previous, at: now,
                            pauseAutoRefresh: e.promptNotApproved)
        } catch let e as UsageError {
            return .failure(kind, error: e.errorDescription ?? "Error", keeping: previous, at: now)
        } catch {
            return .failure(kind, error: error.localizedDescription, keeping: previous, at: now)
        }
    }

    /// Build a UsageWindow from one entry of the `limits` array.
    private func limitWindow(_ entry: [String: Any]) -> UsageWindow? {
        guard entry["percent"] != nil else { return nil }
        return UsageWindow(usedPercent: doubleValue(entry["percent"]),
                           resetsAt: parseISO8601(entry["resets_at"] as? String),
                           isActive: (entry["is_active"] as? Bool) ?? false)
    }

    /// Pull `scope.model.display_name` from a `limits` entry, if present.
    private func modelName(_ entry: [String: Any]) -> String? {
        guard let scope = entry["scope"] as? [String: Any],
              let model = scope["model"] as? [String: Any],
              let name = model["display_name"] as? String,
              !name.isEmpty else {
            return nil
        }
        return name
    }
}
