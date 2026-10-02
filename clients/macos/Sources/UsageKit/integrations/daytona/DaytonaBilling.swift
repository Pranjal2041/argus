import Foundation

/// Daytona's billing service is distinct from the sandbox API. Never performs billing mutations.
@available(macOS 14.0, *)
struct DaytonaBilling: Sendable {
    var client: any HTTPClient
    private let base = "https://billing.app.daytona.io"

    func fetch(organization: String, headers: [String: String], now: Date) async throws -> DaytonaBillingReading {
        // Only an ID, not a provider-controlled URL, can influence the request destination.
        guard !organization.isEmpty, organization.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw IntegrationError.invalidResponse("Invalid Daytona billing organization identity.")
        }
        let path = "/organization/\(organization)"
        let wallet = try await readVersioned(path + "/wallet", headers: headers)
        return try Self.normalize(wallet: wallet, now: now)
    }

    private func readVersioned(_ path: String, headers: [String: String]) async throws -> JSONValue {
        do { return try await client.get(URL(string: base + "/v2" + path)!, headers: headers) }
        catch HTTPFailure.status(let code) where code == 404 || code == 410 {
            return try await client.get(URL(string: base + path)!, headers: headers)
        }
    }

    static func normalize(wallet: JSONValue, now: Date) throws -> DaytonaBillingReading {
        guard let balance = wallet["balanceCents"].double, balance.isFinite else {
            throw IntegrationError.invalidResponse("Daytona did not report a valid wallet balance.")
        }
        return DaytonaBillingReading(balanceUSD: balance / 100)
    }
}

@available(macOS 14.0, *)
struct DaytonaBillingReading: Sendable {
    var balanceUSD: Double
}
