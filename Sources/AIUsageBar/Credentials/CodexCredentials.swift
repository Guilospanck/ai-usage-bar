import Foundation

/// Reads the OAuth token the Codex CLI stores at `~/.codex/auth.json`.
///
/// Shape (fields we care about):
/// ```
/// { "tokens": { "access_token": "…", "account_id": "…", "id_token": "…" } }
/// ```
/// `account_id` is sometimes absent from `tokens`; when so we recover it from
/// the `chatgpt_account_id` claim inside the `id_token` JWT.
enum CodexCredentials {

    struct Token {
        let accessToken: String
        let accountId: String?
    }

    static func load() throws -> Token {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/auth.json")
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String,
              !access.isEmpty else {
            throw UsageError.notAuthenticated("run `codex` to sign in")
        }

        var accountId = tokens["account_id"] as? String
        if accountId == nil, let idToken = tokens["id_token"] as? String {
            accountId = chatgptAccountId(fromJWT: idToken)
        }
        return Token(accessToken: access, accountId: accountId)
    }

    /// Decode the JWT payload and pull `…/auth`.chatgpt_account_id if present.
    private static func chatgptAccountId(fromJWT jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2, let payload = base64URLDecode(String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        for (key, value) in obj {
            if key.hasSuffix("/auth"), let auth = value as? [String: Any],
               let id = auth["chatgpt_account_id"] as? String {
                return id
            }
        }
        return nil
    }

    private static func base64URLDecode(_ input: String) -> Data? {
        var s = input.replacingOccurrences(of: "-", with: "+")
                     .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }
}
