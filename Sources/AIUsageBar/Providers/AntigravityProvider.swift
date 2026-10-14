import Foundation

/// Parses the CLI's structured command report, never its human-readable response.
func parseAntigravityUsage(from data: Data) throws -> [NamedWindow] {
    struct Report: Decodable {
        let status: String
        let command: Command?
        struct Command: Decodable {
            let name: String
            let data: QuotaData?
        }
        struct QuotaData: Decodable { let groups: [Group] }
        struct Group: Decodable {
            let name: String
            let buckets: [Bucket]
        }
        struct Bucket: Decodable {
            let name: String
            let window: String
            let remaining_fraction: Double?
            let reset_time: String?
        }
    }
    let report = try JSONDecoder().decode(Report.self, from: data)
    guard report.status == "SUCCESS", let command = report.command,
        command.name == "usage", let quota = command.data else {
        throw UsageError.badResponse("agy did not return a successful usage report; run `agy` to check sign-in")
    }
    let windows = quota.groups.flatMap { group in
        group.buckets.compactMap { bucket -> NamedWindow? in
            guard let remaining = bucket.remaining_fraction, remaining.isFinite,
                (0...1).contains(remaining) else { return nil }
            let period: String
            switch bucket.window {
            case "weekly": period = "Weekly"
            case "five_hour", "five-hour", "fiveHour", "session": period = "5-hour"
            default: period = bucket.name
            }
            return NamedWindow(
                label: "\(group.name) · \(period)",
                window: UsageWindow(
                    usedPercent: (1 - remaining) * 100,
                    resetsAt: parseISO8601(bucket.reset_time)))
        }
    }
    guard !windows.isEmpty else {
        throw UsageError.badResponse("No measured quota groups in agy usage report")
    }
    return windows
}

struct AntigravityProvider: UsageProvider {
    let kind: ProviderKind = .antigravity

    func fetch(previous: ProviderUsage?) async -> ProviderUsage {
        let now = Date()
        do {
            let data = try await AntigravityUsageCommand.run()
            return ProviderUsage(
                provider: kind, planName: "Shared group quotas",
                fiveHour: nil, weekly: nil,
                scoped: try parseAntigravityUsage(from: data),
                error: nil, fetchedAt: now)
        } catch {
            return .failure(kind, error: error.localizedDescription, keeping: previous, at: now)
        }
    }
}
