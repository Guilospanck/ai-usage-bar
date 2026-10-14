import Foundation

struct ModelsResponse: Decodable {
    let models: [String: Model]

    struct Model: Decodable {
        let displayName: String?
        let quotaInfo: QuotaInfo?
    }

    struct QuotaInfo: Decodable {
        let remainingFraction: Double?
        let resetTime: String?
    }
}

struct UsageResponse: Encodable {
    let models: [ModelUsage]

    struct ModelUsage: Encodable {
        let name: String
        let remainingPercent: Double?
        let resetTime: String?
    }
}

func parseGeminiUsage(from data: Data) throws -> UsageResponse {
    let response = try JSONDecoder().decode(ModelsResponse.self, from: data)

    let models = response.models.map { key, model in
        UsageResponse.ModelUsage(
            name: model.displayName ?? key,
            remainingPercent: model.quotaInfo?.remainingFraction.map { $0 * 100 },
            resetTime: model.quotaInfo?.resetTime
        )
    }

    return UsageResponse(
        models: models.sorted { $0.name < $1.name }
    )
}

struct GeminiProvider: UsageProvider {
    let kind: ProviderKind = .gemini

    private let url = URL(
        string: "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")!

    func fetch(previous: ProviderUsage?) async -> ProviderUsage {
        let now = Date()
        do {
            let token = try await GeminiCredentials.load()
            let headers = [
                "Authorization": "Bearer \(token.token.accessToken)",
                "User-Agent": "antigravity",
                "Content-Type": "application/json",
            ]

            let data = try await HTTP.call(url, headers: headers, method: .POST)
            let root = try parseGeminiUsage(from: data)

            let gemini_3_8 = root.models.first(where: { $0.name == "gemini-3.8-lash-tiered" })

            if gemini_3_8 == nil {
                throw UsageError.badResponse("no gemini 3.8")
            }

            func window(_ obj: UsageResponse.ModelUsage) -> UsageWindow {
                let resetsAt = ISO8601DateFormatter().date(from: obj.resetTime!)
                let usedPercent = obj.remainingPercent!

                return UsageWindow(usedPercent: usedPercent, resetsAt: resetsAt)
            }

            var scoped: [NamedWindow] = []
            let monthly: NamedWindow = NamedWindow(label: "Monthly", window: window(gemini_3_8!))
            scoped.append(monthly)

            return ProviderUsage(
                provider: kind,
                planName: "Subscription",
                fiveHour: nil,
                weekly: nil,
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
}
