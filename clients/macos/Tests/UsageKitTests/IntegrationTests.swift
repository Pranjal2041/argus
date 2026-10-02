@testable import UsageKit
import XCTest

@available(macOS 14.0, *)
final class IntegrationTests: XCTestCase {
    func testAllProvidersReturnDistinctSourcesAndConsistentTotals() async throws {
        let results = await IntegrationRegistry.demo.fetchAll()
        XCTAssertEqual(results.count, 8)
        XCTAssertTrue(results.allSatisfy { $0.error == nil })
        let sources = results.flatMap(\.sources)
        XCTAssertEqual(sources.count, 22)
        XCTAssertEqual(Set(sources.map(\.id)).count, 22)
        XCTAssertEqual(sources.filter { $0.integration == .claude }.count, 10)
        XCTAssertEqual(sources.filter { $0.integration == .codex }.count, 5)
        XCTAssertEqual(sources.filter { $0.integration == .modal }.count, 2)
        let daytona = try XCTUnwrap(sources.first { $0.integration == .daytona }?.compute)
        XCTAssertEqual(daytona.resources.count, 8)
        XCTAssertEqual(try XCTUnwrap(daytona.hourlyRate), 0.34, accuracy: 0.00001)
        XCTAssertEqual(daytona.idle.compactMap(\.hourlyRate).reduce(0, +), 0.07, accuracy: 0.00001)
        XCTAssertEqual(daytona.allocatedCPU, 14)
        XCTAssertEqual(daytona.allocatedMemory, 28)
        let api = try XCTUnwrap(sources.first { $0.integration == .openaiAPI }?.spend)
        XCTAssertEqual(api.dailySpend.reduce(0, +), api.spent, accuracy: 0.00001)
        XCTAssertEqual(api.breakdown.reduce(0) { $0 + $1.spent }, api.spent, accuracy: 0.00001)
        for source in sources {
            for drive in source.storage?.drives ?? [] {
                XCTAssertEqual(drive.usedGB + drive.freeGB, drive.capacityGB, accuracy: 0.00001)
                XCTAssertEqual(drive.breakdown.reduce(0) { $0 + $1.sizeGB }, drive.usedGB, accuracy: 0.00001)
            }
        }
    }

    func testAttentionAndSearchPointToTheCorrectAccountOrDrive() async throws {
        let sources = await IntegrationRegistry.demo.fetchAll().flatMap(\.sources)
        let attention = DashboardLogic.attention(in: sources)
        XCTAssertEqual(attention.count, 4)
        XCTAssertTrue(attention.contains { $0.selection.sourceID == "claude-demo-7" })
        XCTAssertTrue(attention.contains { $0.selection.sourceID == "codex-research" })
        XCTAssertTrue(attention.contains { $0.selection.driveID == "d-projects" })
        XCTAssertEqual(DashboardLogic.search("Research", in: sources).first?.selection.sourceID, "codex-research")
        XCTAssertEqual(DashboardLogic.search("D: · Projects", in: sources).first?.selection.driveID, "d-projects")
        XCTAssertTrue(DashboardLogic.search("does-not-exist", in: sources).isEmpty)
    }

    @MainActor
    func testRefreshPreservesOfflineTimestampAndAddedAccounts() async throws {
        let defaults = UserDefaults(suiteName: "com.pranjal.usage.tests.\(UUID())")!
        let store = UsageStore(defaults: defaults)
        await store.refresh()
        let before = try XCTUnwrap(store.sources.first { $0.id == "windows-pc" })
        XCTAssertFalse(try XCTUnwrap(before.storage).online)
        XCTAssertTrue(store.addSource(.codex, label: "  Demo lab  "))
        XCTAssertEqual(store.sources.filter { $0.integration == .codex }.count, 6)
        let id = try XCTUnwrap(store.selection?.sourceID)
        await store.refresh()
        XCTAssertEqual(store.sources.first { $0.id == "windows-pc" }?.observedAt, before.observedAt)
        XCTAssertEqual(store.sources.first { $0.id == id }?.account, "Demo lab")
        let restored = UsageStore(defaults: defaults)
        await restored.refresh()
        XCTAssertEqual(restored.sources.first { $0.id == id }?.account, "Demo lab")
        restored.removeAddedSource(id)
        XCTAssertEqual(restored.sources.count, 22)
        XCTAssertFalse(restored.addSource(.codex, label: "  "))
    }

    func testOneFailingProviderDoesNotDiscardOthers() async throws {
        struct Failing: UsageIntegration {
            let id = IntegrationID.daytona
            func fetchSources() async throws -> [UsageSource] { throw URLError(.notConnectedToInternet) }
        }
        let registry = IntegrationRegistry(adapters: [Failing(), CodexIntegration()])
        let results = await registry.fetchAll()
        XCTAssertNotNil(results.first { $0.integration == .daytona }?.error)
        XCTAssertEqual(results.first { $0.integration == .codex }?.sources.count, 5)
    }
}
