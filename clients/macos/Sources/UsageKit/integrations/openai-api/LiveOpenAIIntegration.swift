import Foundation

@available(macOS 14.0, *)
struct LiveOpenAIIntegration: UsageIntegration {
    let id = IntegrationID.openaiAPI
    let configuration: SourceConfiguration
    var client: any HTTPClient = URLSessionHTTPClient()
    var descriptor: IntegrationDescriptor? { configuration.descriptor }

    func fetchSources() async throws -> [UsageSource] {
        let credential = try CredentialReader.values(for: configuration, required: ["OPENAI_ADMIN_KEY"])
        let headers = ["Authorization": "Bearer " + credential["OPENAI_ADMIN_KEY"]!]
        let now = Date.now
        var buckets: [JSONValue] = [], cursor: String?, visited = Set<String>()
        do {
            repeat {
                var url = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
                url.queryItems = [
                    URLQueryItem(name: "start_time", value: String(Int(UsageCalendar.monthStart(now).timeIntervalSince1970))),
                    URLQueryItem(name: "end_time", value: String(Int(now.timeIntervalSince1970))),
                    URLQueryItem(name: "bucket_width", value: "1d"), URLQueryItem(name: "limit", value: "31"),
                    URLQueryItem(name: "group_by", value: "project_id"),
                ]
                if let cursor { url.queryItems?.append(URLQueryItem(name: "page", value: cursor)) }
                let response = try await client.get(url.url!, headers: headers)
                guard let data = response["data"].array else { throw IntegrationError.invalidResponse("OpenAI returned an unexpected costs response.") }
                buckets.append(contentsOf: data)
                cursor = response["next_page"].string
                if response["has_more"].bool == true, cursor == nil { throw IntegrationError.invalidResponse("OpenAI omitted the next usage page.") }
                if let cursor, !visited.insert(cursor).inserted || visited.count > 100 {
                    throw IntegrationError.invalidResponse("OpenAI usage pagination did not complete safely.")
                }
            } while cursor != nil
        } catch HTTPFailure.status(let status) where status == 401 || status == 403 {
            throw IntegrationError.permission("An OpenAI organization admin key with api.usage.read is required. Ordinary project/person keys cannot read organization costs.")
        }
        return [try Self.normalize(buckets: buckets, configuration: configuration, now: now)]
    }

    static func normalize(buckets: [JSONValue], configuration: SourceConfiguration, now: Date) throws -> UsageSource {
        var entries: [(Date, Double)] = [], totals: [String: Double] = [:]
        var seenBuckets = Set<Double>()
        for bucket in buckets {
            guard let time = bucket["start_time"].double, let results = bucket["results"].array else {
                throw IntegrationError.invalidResponse("OpenAI returned an invalid cost bucket.")
            }
            guard seenBuckets.insert(time).inserted else { throw IntegrationError.invalidResponse("OpenAI returned overlapping cost pages.") }
            let date = Date(timeIntervalSince1970: time)
            guard date >= UsageCalendar.monthStart(now), date <= now else { continue }
            for result in results {
                guard let cost = result["amount"]["value"].double, cost.isFinite,
                      result["amount"]["currency"].string?.lowercased() == "usd" else {
                    throw IntegrationError.invalidResponse("OpenAI returned an invalid amount or unsupported billing currency.")
                }
                entries.append((date, cost))
                let project = result["project_id"].string ?? "Organization · unattributed"
                totals[project, default: 0] += cost
            }
        }
        let series = UsageCalendar.dailySeries(entries, from: UsageCalendar.monthStart(now), through: now)
        let today = entries.filter { UsageCalendar.utc.isDate($0.0, inSameDayAs: now) }.reduce(0) { $0 + $1.1 }
        var spend = SpendUsage(spent: entries.reduce(0) { $0 + $1.1 }, budget: configuration.budgetUSD, today: today,
                               dailySpend: series.values, breakdown: totals.sorted { $0.value > $1.value }.map {
                                   SpendBreakdown(name: $0.key, requests: nil, tokens: nil, spent: $0.value)
                               })
        spend.dailySpendDates = series.dates; spend.spendingThrough = now
        return UsageSource(id: configuration.id, integration: .openaiAPI, account: configuration.label, observedAt: now,
                           payload: .spend(spend), origin: .live,
                           notes: ["Organization Costs API, month-to-date in UTC. Billing can lag. Project IDs identify attribution; unattributed charges remain separate.",
                                   "The Costs API does not report request/token counts or an account spending limit. No limit is assumed; an optional budget is a local target only."])
    }
}
