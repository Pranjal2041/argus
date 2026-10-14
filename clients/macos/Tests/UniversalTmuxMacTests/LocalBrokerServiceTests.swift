import XCTest
@testable import UniversalTmuxMac

final class LocalBrokerServiceTests: XCTestCase {
    func testColdStartupOwnsBrokerWithoutCreatingUserPanelsOrPersistingSecrets() throws {
        for resource in [URL(fileURLWithPath: "/Applications/Argus.app/Contents/Resources"), nil] {
            let service = try LocalBrokerServiceLauncher.specification(
                home: URL(fileURLWithPath: "/Users/test"), resources: resource,
                environment: ["UT_TMUX_SOCKET": "second", "UT_LOCAL_PORT": "8732", "TS_AUTHKEY": "secret"],
                executable: { _ in true }
            )
            XCTAssertEqual(Array(service.arguments.dropFirst()), ["-L", "second", "--broker-only"])
            XCTAssertEqual(service.arguments.first, resource?.appendingPathComponent("ut").path ?? "/Users/test/.universal-tmux/ut")
            let plist = service.propertyList(logs: URL(fileURLWithPath: "/tmp/logs"))
            XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
            XCTAssertEqual(plist["StartInterval"] as? Int, 15)
            XCTAssertNil(plist["KeepAlive"])
            XCTAssertEqual(plist["ProcessType"] as? String, "Background")
            XCTAssertNil(service.environment["TS_AUTHKEY"])
            XCTAssertEqual(service.environment["UT_LOCAL_PORT"], "8732")
        }
    }

    func testMissingDependencyReportsStartupFailure() {
        XCTAssertThrowsError(try LocalBrokerServiceLauncher.specification(
            home: URL(fileURLWithPath: "/Users/test"), resources: nil, environment: [:], executable: { _ in false }
        ))
    }

    func testAppServingWorkerPreservesAppResourcePolicyWithoutChangingBrokerPolicy() throws {
        let executable = URL(fileURLWithPath: "/Applications/Test.app/Contents/MacOS/Test")
        let worker = WorkspaceServiceLauncher.specification(executable: executable, build: 123)
        let plist = worker.propertyList(logs: URL(fileURLWithPath: "/tmp/logs"))
        XCTAssertEqual(plist["ProcessType"] as? String, "Interactive")
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
        XCTAssertNil(plist["StartInterval"])
        XCTAssertEqual(worker.arguments, [executable.path, "--workspace-worker", "--build=123.0"])

        let broker = try LocalBrokerServiceLauncher.specification(
            home: URL(fileURLWithPath: "/Users/test"), resources: nil,
            environment: [:], executable: { _ in true })
        XCTAssertEqual(broker.processType, .background)
    }

    func testResourcePolicyChangeReloadsOnlyItsServiceAndRemainsIdempotent() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        var loaded = false
        var calls: [[String]] = []
        let run: ([String]) -> Int32 = { args in
            calls.append(args)
            switch args[0] {
            case "print": return loaded ? 0 : 1
            case "bootstrap": loaded = true; return 0
            case "bootout": loaded = false; return 0
            default: XCTFail("unexpected command"); return 1
            }
        }
        var service = LaunchAgentService(label: "test.policy", arguments: ["/bin/service"], logName: "test.log")
        try service.ensureRunning(home: home, uid: 123, run: run)
        calls = []
        service.processType = .interactive
        try service.ensureRunning(home: home, uid: 123, run: run)
        XCTAssertEqual(calls, [
            ["bootout", "gui/123/test.policy"], ["print", "gui/123/test.policy"],
            ["bootstrap", "gui/123", home.appendingPathComponent("Library/LaunchAgents/test.policy.plist").path],
        ])
        let saved = try Data(contentsOf: home.appendingPathComponent("Library/LaunchAgents/test.policy.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: saved, format: nil) as? [String: Any])
        XCTAssertEqual(plist["ProcessType"] as? String, "Interactive")
        calls = []
        try service.ensureRunning(home: home, uid: 123, run: run)
        XCTAssertEqual(calls, [["print", "gui/123/test.policy"]])
    }

    func testLaunchAgentsInstallIdempotentlyAndReloadChangedDefinitions() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        for keepAlive in [false, true] {
            var loaded = false
            var calls: [[String]] = []
            let run: ([String]) -> Int32 = { args in
                calls.append(args)
                switch args[0] {
                case "print": return loaded ? 0 : 1
                case "bootstrap": loaded = true; return 0
                case "bootout": loaded = false; return 0
                default: XCTFail("unexpected command"); return 1
                }
            }
            let service = LaunchAgentService(label: "test.\(keepAlive)", arguments: ["/bin/service"],
                                             keepAlive: keepAlive, interval: keepAlive ? nil : 15, logName: "test.log")
            try service.ensureRunning(home: home, uid: 123, run: run)
            XCTAssertEqual(calls.map { $0[0] }, ["bootout", "print", "bootstrap"])
            calls = []
            try service.ensureRunning(home: home, uid: 123, run: run)
            XCTAssertEqual(calls, [["print", "gui/123/test.\(keepAlive)"]])
            calls = []
            let changed = LaunchAgentService(label: service.label, arguments: ["/bin/service", "--new"], logName: "test.log")
            try changed.ensureRunning(home: home, uid: 123, run: run)
            XCTAssertEqual(calls.map { $0[0] }, ["bootout", "print", "bootstrap"])
        }
    }

    func testBootstrapFailureIsNotReportedAsSuccess() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertThrowsError(try LaunchAgentService(label: "test.failure", arguments: ["missing"], logName: "test.log")
            .ensureRunning(home: home, uid: 123, run: { _ in 1 }))
    }

    func testConcurrentRegistrationWinnerIsAccepted() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        var loaded = false
        try LaunchAgentService(label: "test.race", arguments: ["/bin/service"], logName: "test.log")
            .ensureRunning(home: home, uid: 123, run: { args in
                if args[0] == "bootstrap" { loaded = true; return 1 }
                return args[0] == "print" && loaded ? 0 : 1
            })
    }
}
