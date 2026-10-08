import Foundation

/// A provider owns its transport, but the registry owns the deadline and
/// single-flight contract. Cancellation-uncooperative work can occupy only its
/// own slot; it cannot hold up a batch or accumulate duplicate fetches.
@available(macOS 14.0, *)
actor IntegrationFetchCoordinator {
    private final class Flight {
        let id = UUID()
        let adapter: any UsageIntegration
        var operation: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var result: IntegrationResult?
        var waiters: [CheckedContinuation<IntegrationResult, Never>] = []
        init(_ adapter: any UsageIntegration) { self.adapter = adapter }
    }

    private var flights: [String: Flight] = [:]
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 90) { self.timeout = timeout }

    func fetch(_ adapter: any UsageIntegration) async -> IntegrationResult {
        let key = adapter.descriptor?.sourceID ?? adapter.id.rawValue
        let flight: Flight
        if let existing = flights[key] { flight = existing }
        else {
            flight = Flight(adapter)
            flights[key] = flight
            let id = flight.id
            flight.operation = Task.detached(priority: .utility) {
                let result: IntegrationResult
                do {
                    result = IntegrationResult(integration: adapter.id, sources: try await adapter.fetchSources(), descriptor: adapter.descriptor)
                } catch {
                    result = Self.failure(adapter, error: error)
                }
                await self.complete(key, id: id, result: result)
            }
            flight.deadline = Task {
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                self.expire(key, id: id)
            }
        }
        if let result = flight.result { return result }
        return await withCheckedContinuation { flight.waiters.append($0) }
    }

    private func expire(_ key: String, id: UUID) {
        guard let flight = flights[key], flight.id == id, flight.result == nil else { return }
        resolve(flight, Self.failure(flight.adapter, error: IntegrationError.timeout))
        flight.operation?.cancel()
        flight.deadline = nil
        // Keep the slot until the underlying operation really exits. Starting a
        // fresh task on every retry would leak work when cancellation is ignored.
    }

    private func complete(_ key: String, id: UUID, result: IntegrationResult) {
        guard let flight = flights[key], flight.id == id else { return }
        flight.deadline?.cancel()
        if flight.result == nil { resolve(flight, result) }
        flights[key] = nil // a late result never replaces the timeout already delivered
    }

    private func resolve(_ flight: Flight, _ result: IntegrationResult) {
        flight.result = result
        let waiters = flight.waiters
        flight.waiters.removeAll()
        waiters.forEach { $0.resume(returning: result) }
    }

    nonisolated private static func failure(_ adapter: any UsageIntegration, error: Error) -> IntegrationResult {
        let known = error as? IntegrationError
        return IntegrationResult(integration: adapter.id, sources: [],
            error: known?.errorDescription ?? "Couldn't refresh \(adapter.id.name). It will retry automatically.",
            descriptor: adapter.descriptor, needsAuthentication: known?.needsAuthentication ?? false,
            errorTitle: known?.title ?? "Unavailable")
    }
}
