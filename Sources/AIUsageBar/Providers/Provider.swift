import Foundation

/// A source of subscription usage data.
/// `Sendable` so instances can cross into `UsageStore`'s task group under
/// Swift 6 strict concurrency (both conformers are immutable value types).
protocol UsageProvider: Sendable {
    var kind: ProviderKind { get }
    /// Fetch the latest snapshot. Must never throw — failures are folded into
    /// `ProviderUsage.error` so one provider going down never blocks the other.
    func fetch(previous: ProviderUsage?) async -> ProviderUsage
}

/// Small shared helpers for the HTTP providers.
enum HTTP {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    /// Perform a GET and return the raw body, mapping status codes to UsageError.
    static func get(_ url: URL, headers: [String: String]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.badResponse("No HTTP response")
        }
        switch http.statusCode {
        case 200...299: return data
        case 401, 403: throw UsageError.unauthorized
        case 429: throw UsageError.rateLimited
        default: throw UsageError.http(http.statusCode)
        }
    }
}

/// Coerce a JSON number (Int, Double, or numeric String) to Double, defaulting to 0.
func doubleValue(_ any: Any?) -> Double {
    switch any {
    case let d as Double: return d
    case let i as Int: return Double(i)
    case let s as String: return Double(s) ?? 0
    default: return 0
    }
}

/// Parse an ISO-8601 timestamp (with or without fractional seconds).
func parseISO8601(_ string: String?) -> Date? {
    guard let string else { return nil }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFraction.date(from: string) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: string)
}
