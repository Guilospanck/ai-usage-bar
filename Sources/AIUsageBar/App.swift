import AppKit

/// Entry point. Uses the canonical `@main` + `@MainActor main()` pattern (the
/// same one SwiftUI's `App` protocol uses) so the entry runs on the main actor
/// and can construct the main-actor-isolated `AppDelegate` under Swift 6.
@main
struct AIUsageBarApp {
    @MainActor
    static func main() {
        // `AIUsageBar --probe` fetches once, prints results, and exits — handy
        // for verifying credentials + endpoints without the menu bar.
        if CommandLine.arguments.contains("--probe") {
            runProbe()
            return
        }
        // `AIUsageBar --dump` prints raw HTTP status + response body for each
        // endpoint, to diagnose parsing/shape issues. Tokens are only sent in
        // headers and never printed, but response bodies can contain PII (email,
        // account/user id), so the command warns before dumping.
        if CommandLine.arguments.contains("--dump") {
            runDump()
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    /// Headless one-shot fetch used by `--probe`.
    @MainActor
    private static func runProbe() {
        let providers: [UsageProvider] = [AnthropicProvider(), OpenAIProvider()]
        let sema = DispatchSemaphore(value: 0)
        // Detached so the fetches run off the main actor — we block the main
        // thread on `sema.wait()` below, so a main-actor Task would deadlock.
        Task.detached {
            for p in providers {
                let u = await p.fetch(previous: nil)
                print("── \(u.provider.rawValue) ─────────────────────────")
                if let plan = u.planName { print("  plan:   \(plan)") }
                if let e = u.error { print("  error:  \(e)") }
                if let w = u.fiveHour {
                    print("  5-hour: \(Format.percent(w.usedPercent))  \(Format.resetCountdown(w.resetsAt) ?? "")")
                }
                if let w = u.weekly {
                    print("  weekly: \(Format.percent(w.usedPercent))  \(Format.resetCountdown(w.resetsAt) ?? "")")
                }
                for named in u.scoped {
                    let active = named.window.isActive ? " (active)" : ""
                    print("  \(named.label): \(Format.percent(named.window.usedPercent))  \(Format.resetCountdown(named.window.resetsAt) ?? "")\(active)")
                }
            }
            sema.signal()
        }
        sema.wait()
    }

    /// Raw HTTP dump used by `--dump`.
    @MainActor
    private static func runDump() {
        let sema = DispatchSemaphore(value: 0)
        Task.detached {
            print("⚠ Output below may include personal info from the API response")
            print("  (email, account/user id). Redact before sharing publicly.\n")

            // Claude
            print("══ Claude: api.anthropic.com/api/oauth/usage ══")
            do {
                let t = try ClaudeCredentials.load()
                await rawDump("https://api.anthropic.com/api/oauth/usage", headers: [
                    "Authorization": "Bearer \(t.accessToken)",
                    "anthropic-beta": "oauth-2025-04-20",
                    "User-Agent": "claude-code/2.1.183",
                    "Content-Type": "application/json"
                ])
            } catch { print("  creds error: \(error.localizedDescription)") }

            // OpenAI / Codex
            print("\n══ OpenAI: chatgpt.com/backend-api/wham/usage ══")
            do {
                let t = try CodexCredentials.load()
                print("  account_id: \(t.accountId ?? "‹none — header omitted›")")
                var headers = [
                    "Authorization": "Bearer \(t.accessToken)",
                    "User-Agent": "codex-cli",
                    "Content-Type": "application/json"
                ]
                if let id = t.accountId { headers["ChatGPT-Account-Id"] = id }
                await rawDump("https://chatgpt.com/backend-api/wham/usage", headers: headers)
            } catch { print("  creds error: \(error.localizedDescription)") }

            sema.signal()
        }
        sema.wait()
    }

    private static func rawDump(_ urlString: String, headers: [String: String]) async {
        guard let url = URL(string: urlString) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        do {
            // Ephemeral session: never persist these (PII-bearing) responses or
            // cookies to disk — matches the rest of the app.
            let (data, response) = try await HTTP.session.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("  HTTP \(code)")
            let body = String(data: data, encoding: .utf8) ?? "‹non-utf8 body›"
            print(body.count > 6000 ? String(body.prefix(6000)) + "…(truncated)" : body)
        } catch {
            print("  request error: \(error.localizedDescription)")
        }
    }
}
