import Foundation

@available(macOS 14.0, *)
struct LiveDaytonaIntegration: UsageIntegration {
    let id = IntegrationID.daytona
    let configuration: SourceConfiguration
    var client: any HTTPClient = URLSessionHTTPClient()
    var descriptor: IntegrationDescriptor? { configuration.descriptor }
    private let base = "https://app.daytona.io/api"

    func fetchSources() async throws -> [UsageSource] {
        let credential = try CredentialReader.values(for: configuration, required: ["DAYTONA_API_KEY"])
        let headers = ["Authorization": "Bearer " + credential["DAYTONA_API_KEY"]!]
        var sandboxes: [JSONValue] = [], cursor: String?, visited = Set<String>()
        do {
            repeat {
                var url = URLComponents(string: base + "/sandbox")!
                url.queryItems = [URLQueryItem(name: "limit", value: "200")]
                if let cursor { url.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
                let response = try await client.get(url.url!, headers: headers)
                guard let page = response["items"].array else { throw IntegrationError.invalidResponse("Daytona returned an unexpected sandbox list.") }
                sandboxes.append(contentsOf: page)
                cursor = response["nextCursor"].string
                if let cursor, !visited.insert(cursor).inserted || visited.count > 100 {
                    throw IntegrationError.invalidResponse("Daytona pagination did not complete safely.")
                }
            } while cursor != nil
        } catch HTTPFailure.status(let status) where status == 401 || status == 403 {
            throw IntegrationError.authentication("Daytona rejected sandbox access. Check the API key's organization and permissions.")
        }
        var notes = ["Read-only sandbox inventory. Only started sandboxes count as running. Stopped and paused sandboxes can still incur disk charges; archived sandboxes are not billed."]
        var capabilities = [SourceCapability(id: "inventory", label: "Sandbox inventory", status: .available, message: "All sandbox pages were fetched successfully.")]
        var usage: JSONValue?
        var organization: String?
        do {
            let details = try await client.get(URL(string: base + "/api-keys/current")!, headers: headers)
            organization = details["organizationId"].string
            if let organization {
                // Encode the provider-returned ID as a single path segment.
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
                guard let safeID = organization.addingPercentEncoding(withAllowedCharacters: allowed) else { throw IntegrationError.invalidResponse("Invalid Daytona organization identity.") }
                usage = try await client.get(URL(string: base + "/organizations/" + safeID + "/usage")!, headers: headers)
                capabilities.append(SourceCapability(id: "limits", label: "Organization limits", status: .available, message: "Regional resource usage and quotas are connected."))
            } else {
                capabilities.append(SourceCapability(id: "limits", label: "Organization limits", status: .unavailable, message: "The API key did not report an organization identity."))
            }
        } catch HTTPFailure.status(let status) where status == 401 || status == 403 {
            capabilities.append(SourceCapability(id: "limits", label: "Organization limits", status: .accessRequired,
                message: "Daytona denied organization limits (HTTP \(status)). Use a key with read:limits, then check the connection again."))
        } catch is CancellationError { throw CancellationError() }
        catch { capabilities.append(SourceCapability(id: "limits", label: "Organization limits", status: .unavailable, message: "Organization limits could not be refreshed. Sandbox inventory is current.")) }
        var source = try Self.normalize(sandboxes: sandboxes, usage: usage, configuration: configuration, now: .now)
        if let organization {
            do {
                let analytics = try await DaytonaAnalytics(client: client).fetch(organization: organization, headers: headers, now: source.observedAt)
                if var compute = source.compute {
                    compute.spent = analytics.spentUSD; compute.periodSandboxCount = analytics.sandboxCount
                    compute.billingBreakdown = analytics.breakdown; compute.spendBreakdownTitle = "Month-to-date by sandbox"
                    compute.dailySpend = analytics.dailySpend; compute.dailySpendDates = analytics.dates
                    compute.spendingThrough = analytics.through
                    compute.spendChartTitle = "CPU, memory & storage · daily"
                    compute.spendChartNote = "This provider chart excludes GPU charges and can lag behind the all-resource total above. UTC days."
                    source.payload = .compute(compute)
                }
                notes += analytics.notes
                capabilities.append(SourceCapability(id: "spending", label: "Spending analytics", status: .available,
                    message: "Calendar-month resource spending from Daytona analytics, including historical and deleted sandboxes. Prices are USD; telemetry may lag final billing."))
            } catch HTTPFailure.status(let status) where status == 401 || status == 403 {
                capabilities.append(SourceCapability(id: "spending", label: "Spending analytics", status: .accessRequired,
                    message: "Daytona analytics rejected this request (HTTP \(status)). This is independent of wallet access. Check again; analytics supports API keys with read:billing or legacy write:sandboxes access."))
            } catch is CancellationError { throw CancellationError() }
            catch { capabilities.append(SourceCapability(id: "spending", label: "Spending analytics", status: .unavailable, message: "Spending analytics could not be refreshed; inventory remains available.")) }
            do {
                let billing = try await DaytonaBilling(client: client).fetch(organization: organization, headers: headers, now: source.observedAt)
                if var compute = source.compute {
                    compute.accountBalanceUSD = billing.balanceUSD
                    source.payload = .compute(compute)
                }
                capabilities.append(SourceCapability(id: "wallet", label: "Wallet balance (optional)", status: .available,
                    message: "Balance from Daytona's separate billing service.", isOptional: true))
            } catch HTTPFailure.status(let status) where status == 401 || status == 403 {
                capabilities.append(SourceCapability(id: "wallet", label: "Wallet balance (optional)", status: .unavailable,
                    message: "The separate wallet service rejected API-key authentication (HTTP \(status)); it documents JWT account authentication. This does not mean your key lacks full access and does not block spending analytics. View the balance in Daytona's dashboard.", isOptional: true))
            } catch is CancellationError { throw CancellationError() }
            catch { capabilities.append(SourceCapability(id: "wallet", label: "Wallet balance (optional)", status: .unavailable, message: "The optional wallet balance could not be refreshed. Spending analytics is independent.", isOptional: true)) }
        } else {
            capabilities.append(SourceCapability(id: "spending", label: "Spending analytics", status: .unavailable, message: "Analytics requires the organization identity from this key."))
        }
        notes.append("Exact current prices, idle detection, and actual start times are not reported by the sandbox API. Missing data is not zero usage.")
        source.capabilities = capabilities
        source.notes = notes
        return [source]
    }

    static func normalize(sandboxes: [JSONValue], usage: JSONValue?, configuration: SourceConfiguration, now: Date) throws -> UsageSource {
        var seen = Set<String>()
        let resources: [ComputeResource] = try sandboxes.filter { $0["state"].string == "started" }.compactMap { row in
            guard let id = row["id"].string else { throw IntegrationError.invalidResponse("A Daytona sandbox is missing its identity.") }
            guard seen.insert(id).inserted else { return nil }
            let cpu = row["cpu"].double, memory = row["memory"].double
            guard cpu.map({ $0.isFinite && $0 >= 0 }) ?? true, memory.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                throw IntegrationError.invalidResponse("Daytona returned invalid resource allocations.")
            }
            return ComputeResource(id: id, name: row["name"].string ?? id, state: .running,
                                   kind: row["gpuType"].string ?? "Sandbox", startedAt: nil, hourlyRate: nil, cpu: cpu, memoryGiB: memory)
        }
        var compute = ComputeUsage(resources: resources, capacity: nil, spent: nil, budget: configuration.budgetUSD, dailySpend: [])
        compute.idleDetectionAvailable = false; compute.ratesAvailable = false
        let unique = Dictionary(sandboxes.compactMap { row in row["id"].string.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
        compute.inventoryCounts = Dictionary(grouping: unique.values, by: { $0["state"].string ?? "unknown" }).mapValues(\.count)
        // Region/class limits are intentionally not summed into a fictional global pool.
        for region in usage?["regionUsage"].array ?? [] {
            let name = [region["regionId"].string, region["sandboxClass"].string].compactMap { $0 }.joined(separator: " · ")
            for (metric, usedKey, limitKey, unit) in [("CPU", "currentCpuUsage", "totalCpuQuota", "vCPU"), ("Memory", "currentMemoryUsage", "totalMemoryQuota", "GiB"), ("Disk", "currentDiskUsage", "totalDiskQuota", "GiB")] {
                if let used = region[usedKey].double, let limit = region[limitKey].double, used.isFinite, limit.isFinite, used >= 0, limit > 0 {
                    compute.providerCapacity.append(CapacityReading(id: name + metric, label: name + " · " + metric, used: used, limit: limit, unit: unit))
                }
            }
        }
        return UsageSource(id: configuration.id, integration: .daytona, account: configuration.label, observedAt: now,
                           payload: .compute(compute), origin: .live)
    }
}
