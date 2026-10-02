import XCTest
@testable import UsageKit

@available(macOS 14.0, *)
final class DevinIntegrationTests: XCTestCase {
    let configuration = SourceConfiguration(id: "devin", integration: .devin, label: "CLI")
    func testExplicitRemainingWindowsAndACULimitsNormalizeToSharedQuota() throws {
        let output = "Logged in (via Devin).\n  Email: person@example.test\n  Plan: Pro\nDaily: 12.5% remaining\nWeekly quota: 0% left\n"
        let source = try LiveDevinIntegration.normalize(output, configuration: configuration, now: .now)
        XCTAssertEqual(source.quota?.windows.map(\.remainingPercent), [12.5, 0])
        XCTAssertTrue(source.quota?.windows.allSatisfy { $0.resetsAt == nil } == true)
        XCTAssertEqual(source.accountIdentity, "person@example.test")
        let enterprise = try LiveDevinIntegration.normalize("Logged in (via Devin).\nBilling cycle\n920 of 1000 ACUs", configuration: configuration, now: .now)
        XCTAssertEqual(enterprise.quota?.windows.first?.remainingPercent, 8)
        XCTAssertNil(enterprise.quota?.weeklyWindow)
    }

    func testSignedInDoesNotMeanQuotaAvailableAndUnknownNeverMeansFullBalance() {
        for output in ["Logged in (via Devin).\nFailed to fetch quota: ", "Logged in\nNo quota data available.", "Not logged in.", "Logged in\nDaily: 110% remaining", "Logged in\nPlan: Unlimited", "Logged in\n50 ACUs consumed"] {
            XCTAssertThrowsError(try LiveDevinIntegration.normalize(output, configuration: configuration, now: .now))
        }
    }

    func testAdapterOnlyRunsReadOnlyAccountStatus() async throws {
        let runner = DevinCommandFixture()
        var configuration = configuration; configuration.loginProfile = "/fixture/private-profile"
        let result = try await LiveDevinIntegration(configuration: configuration, executable: "/usr/bin/true", runner: runner).fetchSources()
        XCTAssertEqual(result.first?.integration, .devin)
        let arguments = await runner.arguments
        XCTAssertEqual(arguments, [["auth", "status"]])
        let environments = await runner.environments
        XCTAssertEqual(environments.first?["XDG_DATA_HOME"], "/fixture/private-profile/data")
        XCTAssertEqual(environments.first?["HOME"], "/fixture/private-profile")
    }

    func testMissingProfileNeverFallsBackToTheTerminalAccount() async throws {
        let runner = DevinCommandFixture()
        do {
            _ = try await LiveDevinIntegration(configuration: configuration, executable: "/usr/bin/true", runner: runner).fetchSources()
            XCTFail("A missing profile must require sign-in")
        } catch let error as IntegrationError { XCTAssertTrue(error.needsAuthentication) }
        let arguments = await runner.arguments
        XCTAssertTrue(arguments.isEmpty)
    }

    func testMultipleAccountsUseDifferentCredentialRootsAndCheckIdentity() async throws {
        let runner = DevinCommandFixture()
        for path in ["/fixture/first", "/fixture/second"] {
            var configuration = configuration; configuration.loginProfile = path
            _ = try await LiveDevinIntegration(configuration: configuration, executable: "/usr/bin/true", runner: runner).fetchSources()
        }
        let environments = await runner.environments
        XCTAssertEqual(Set(environments.compactMap { $0["XDG_DATA_HOME"] }), ["/fixture/first/data", "/fixture/second/data"])
        var expected = configuration; expected.accountIdentity = "first@example.test"
        XCTAssertThrowsError(try LiveDevinIntegration.normalize("Logged in\nEmail: other@example.test\nDaily: 30% remaining", configuration: expected, now: .now))
    }
}

@available(macOS 14.0, *)
private actor DevinCommandFixture: CommandRunning {
    var arguments: [[String]] = []
    var environments: [[String: String]] = []
    func run(executable: String, arguments: [String], environment: [String: String], timeout: Double) async throws -> CommandOutput {
        self.arguments.append(arguments)
        environments.append(environment)
        return CommandOutput(status: 0, stdout: Data("Logged in\nDaily: 35% remaining".utf8), stderr: Data())
    }
}
