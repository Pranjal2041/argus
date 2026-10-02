import Foundation

@available(macOS 14.0, *)
struct LiveModalIntegration: UsageIntegration {
    let id = IntegrationID.modal
    let configuration: SourceConfiguration
    let executable: String
    var runner: any CommandRunning = CommandRunner()
    var descriptor: IntegrationDescriptor? { configuration.descriptor }
    static let sdkRequirement = "modal==1.5.5"

    func fetchSources() async throws -> [UsageSource] {
        let credentials = try CredentialReader.values(for: configuration, required: ["MODAL_TOKEN_ID", "MODAL_TOKEN_SECRET"])
        var environment = credentials
        if let selected = configuration.environment { environment["MODAL_ENVIRONMENT"] = selected }
        environment["TZ"] = "UTC"
        async let containers = command(["container", "list", "--json"], environment: environment)
        async let month = command(["billing", "report", "--for", "this month", "--json"], environment: environment)
        let values = try await (containers, month)
        // One billing request per workspace/refresh respects Modal's billing rate limit.
        // Today's provider-reported daily bucket is partitioned out by normalize().
        return [try Self.normalize(containers: values.0, month: values.1, today: values.1, configuration: configuration, now: .now)]
    }

    private func command(_ arguments: [String], environment: [String: String], retry: Bool = true) async throws -> JSONValue {
        let result = try await runner.run(executable: executable,
                                         arguments: ["--offline", "--from", Self.sdkRequirement, "modal"] + arguments,
                                         environment: environment, timeout: 35)
        guard result.status == 0 else {
            let diagnostic = String(data: result.stderr + result.stdout, encoding: .utf8)?.lowercased() ?? ""
            if diagnostic.contains("rate limit") {
                if retry {
                    try await Task.sleep(for: .seconds(3))
                    return try await command(arguments, environment: environment, retry: false)
                }
                throw IntegrationError.unavailable("Modal billing is rate-limited. Wait before refreshing; the last reading is preserved.")
            }
            if diagnostic.contains("unauthenticated") || diagnostic.contains("invalid token") || diagnostic.contains("authentication") {
                throw IntegrationError.authentication("Modal rejected this account's token pair. Update its credential file.")
            }
            if diagnostic.contains("permission") || diagnostic.contains("forbidden") {
                throw IntegrationError.permission("This Modal token cannot read workspace billing or containers.")
            }
            if diagnostic.contains("offline") || diagnostic.contains("cache") {
                throw IntegrationError.configuration("Prepare the pinned Modal SDK with scripts/prepare-modal.sh, then refresh.")
            }
            throw IntegrationError.unavailable("Modal \(arguments.prefix(2).joined(separator: " ")) failed (exit \(result.status)). Check the connection and try again.")
        }
        return try JSONValue.decode(result.stdout)
    }

    static func normalize(containers: JSONValue, month: JSONValue, today: JSONValue, configuration: SourceConfiguration, now: Date) throws -> UsageSource {
        guard let rows = containers.array, let monthRows = month.array, let todayRows = today.array else {
            throw IntegrationError.invalidResponse("Modal returned an unexpected report format.")
        }
        let resources: [ComputeResource] = try rows.map { row in
            guard let id = row["container_id"].string else { throw IntegrationError.invalidResponse("A Modal container is missing its identity.") }
            return ComputeResource(id: id, name: row["app_name"].string ?? id, state: .running, kind: "Container",
                                   startedAt: row["start_time"].date, hourlyRate: nil, cpu: nil, memoryGiB: nil)
        }
        let dayStart = UsageCalendar.utc.startOfDay(for: now)
        // Daily reports may already include a partial current day. Replace that day with the
        // finer-grained hourly report; never add overlapping buckets twice.
        let historical = try monthRows.filter { row in
            guard let date = row["interval_start"].date else { throw IntegrationError.invalidResponse("A Modal billing interval is invalid.") }
            return date >= UsageCalendar.monthStart(now) && date < dayStart
        }
        let current = try todayRows.filter { row in
            guard let date = row["interval_start"].date else { throw IntegrationError.invalidResponse("A Modal billing interval is invalid.") }
            return date >= dayStart && date <= now
        }
        let billingRows = historical + current
        var entries: [(Date, Double)] = []
        var projects: [String: (String, Double)] = [:]
        for row in billingRows {
            guard let date = row["interval_start"].date, let cost = row["cost"].double, cost.isFinite else {
                throw IntegrationError.invalidResponse("Modal returned an invalid billing amount.")
            }
            entries.append((date, cost))
            let id = row["object_id"].string ?? "unattributed"
            let label = row["description"].string ?? id
            projects[id] = (label, (projects[id]?.1 ?? 0) + cost)
        }
        let series = UsageCalendar.dailySeries(entries, from: UsageCalendar.monthStart(now), through: now)
        var compute = ComputeUsage(resources: resources, capacity: nil, spent: entries.reduce(0) { $0 + $1.1 },
                                   budget: configuration.budgetUSD, dailySpend: series.values)
        compute.dailySpendDates = series.dates
        compute.spendingThrough = now
        compute.resourceNoun = "containers"
        compute.idleDetectionAvailable = false
        compute.ratesAvailable = false
        compute.billingBreakdown = projects.sorted { $0.value.1 > $1.value.1 }.map {
            SpendBreakdown(name: $0.value.0 + " · " + $0.key, requests: nil, tokens: nil, spent: $0.value.1)
        }
        return UsageSource(id: configuration.id, integration: .modal, account: configuration.label, observedAt: now,
                           payload: .compute(compute), origin: .live,
                           notes: ["Workspace billing, month-to-date in UTC; today's reported bucket may be partial and provider billing can lag. One billing request per refresh; date buckets never overlap.",
                                   "Live containers\(configuration.environment.map { " in \($0)" } ?? " in the default environment"). The CLI does not report their allocated CPU, memory, GPU type, or instantaneous price."])
    }
}
