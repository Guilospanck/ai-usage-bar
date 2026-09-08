import Foundation
import Security

/// Reads the OAuth access token that Claude Code / the Claude CLI stores.
///
/// On recent macOS builds the token lives in the login Keychain under the
/// generic-password service "Claude Code-credentials"; older/other setups keep
/// it in `~/.claude/.credentials.json`. We try the Keychain first, then the file.
enum ClaudeCredentials {

    struct Token {
        let accessToken: String
        let subscriptionType: String?
        let expiresAt: Date?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt < Date()
        }
    }

    static let keychainService = "Claude Code-credentials"

    static func load() throws -> Token {
        if let raw = keychainValue(service: keychainService),
           let token = parse(raw) {
            return token
        }
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/.credentials.json")
        if let data = FileManager.default.contents(atPath: path),
           let raw = String(data: data, encoding: .utf8),
           let token = parse(raw) {
            return token
        }
        throw UsageError.notAuthenticated("run `claude` to sign in")
    }

    /// Parse the `{ "claudeAiOauth": { "accessToken": …, "expiresAt": … } }` blob.
    private static func parse(_ raw: String) -> Token? {
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String,
              !access.isEmpty else {
            return nil
        }
        // expiresAt is epoch milliseconds.
        var expires: Date?
        if let ms = oauth["expiresAt"] as? Double {
            expires = Date(timeIntervalSince1970: ms / 1000.0)
        } else if let ms = oauth["expiresAt"] as? Int {
            expires = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        }
        return Token(accessToken: access,
                     subscriptionType: oauth["subscriptionType"] as? String,
                     expiresAt: expires)
    }

    /// Read a generic-password value from the login Keychain, or nil if absent.
    private static func keychainValue(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
