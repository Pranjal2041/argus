import XCTest
@testable import UniversalTmuxMac

@MainActor
final class MachineLauncherTests: XCTestCase {
    private func machine(_ id: String, _ name: String, host: String = "", local: Bool = false) -> Machine {
        Machine(id: id, name: name, host: host, isLocal: local,
                httpBase: "https://\(id):8722", wsBase: "wss://\(id):8722")
    }

    func testAnnouncementLineNamesTheMachine() {
        XCTAssertEqual(MachineLaunchMatching.announcedMachine(in: "  ARGUS_MACHINE=node7  "), "node7")
        XCTAssertNil(MachineLaunchMatching.announcedMachine(in: "ARGUS_MACHINE="))
        XCTAssertNil(MachineLaunchMatching.announcedMachine(in: "running on node7"))
    }

    func testAnnouncedMachineMatchesNameOrHostAcrossDomainSuffix() {
        let machines = [machine("local", "this mac", local: true),
                        machine("a", "gpu-host", host: "node7.cluster.example"),
                        machine("b", "node8")]
        XCTAssertEqual(MachineLaunchMatching.resolve(announced: "node7", pattern: "", before: [], machines: machines)?.id, "a")
        XCTAssertEqual(MachineLaunchMatching.resolve(announced: "NODE8.cluster.example", pattern: "",
                                                     before: [], machines: machines)?.id, "b")
        // A reused allocation: the announced machine may have existed before the request.
        XCTAssertEqual(MachineLaunchMatching.resolve(announced: "node8", pattern: "", before: ["b"], machines: machines)?.id, "b")
        XCTAssertNil(MachineLaunchMatching.resolve(announced: "node9", pattern: "node*", before: [], machines: machines))
    }

    func testPatternOnlyAcceptsAMachineThatAppearedAfterTheRequest() {
        let machines = [machine("old", "babel-1-1"), machine("new", "babel-2-4"), machine("vm", "cloud-vm-3")]
        XCTAssertEqual(MachineLaunchMatching.resolve(announced: nil, pattern: "babel-*",
                                                     before: ["old"], machines: machines)?.id, "new")
        XCTAssertNil(MachineLaunchMatching.resolve(announced: nil, pattern: "babel-*",
                                                   before: ["old", "new"], machines: machines))
        XCTAssertEqual(MachineLaunchMatching.resolve(announced: nil, pattern: "cloud-vm-*",
                                                     before: [], machines: machines)?.id, "vm")
        XCTAssertNil(MachineLaunchMatching.resolve(announced: nil, pattern: "", before: [], machines: machines))
        // The local machine is never the product of a launcher.
        XCTAssertNil(MachineLaunchMatching.resolve(announced: nil, pattern: "this mac", before: [],
                                                   machines: [machine("local", "this mac", local: true)]))
    }

    func testOutputBufferJoinsSplitWritesAndTreatsCarriageReturnsAsBreaks() {
        let buffer = OutputLineBuffer()
        XCTAssertEqual(buffer.append(Data("PENDING (Prio".utf8)), [])
        XCTAssertEqual(buffer.append(Data("rity)\rRUNNING node7\nARGUS_MA".utf8)), ["PENDING (Priority)", "RUNNING node7"])
        XCTAssertEqual(buffer.finish(Data("CHINE=node7".utf8)), ["ARGUS_MACHINE=node7"])
    }

    func testRequestBecomesReadyWhenTheAnnouncedMachineIsReachable() async throws {
        let app = AppState(isolatedForTesting: true)
        let store = isolatedStore(app)
        store.request(MachineLauncher(name: "test cluster",
                                      command: "echo queued; echo ARGUS_MACHINE=node7-test",
                                      machinePattern: ""))
        try await waitFor { store.runs.first?.phase == .waitingForMachine }
        XCTAssertEqual(store.runs.first?.announcedMachine, "node7-test")
        XCTAssertEqual(store.runs.first?.lastLine, "queued")

        // Listed but not yet answering is not ready: the picker would not offer it.
        app.machines.append(machine("n7", "node7-test.cluster.example"))
        app.statusByMachine["n7"] = .unreachable
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(store.runs.first?.phase, .waitingForMachine)

        app.statusByMachine["n7"] = .reachable
        app.machines = app.machines   // discovery republishes the list
        try await waitFor { store.runs.first?.phase == .ready(machineID: "n7", machineName: "node7-test.cluster.example") }
        XCTAssertEqual(store.lastReady?.machineID, "n7")
    }

    func testFailedCommandReportsItsLastLine() async throws {
        let store = isolatedStore(AppState(isolatedForTesting: true))
        store.request(MachineLauncher(name: "broken", command: "echo 'sbatch: error: invalid partition'; exit 3"))
        try await waitFor { store.runs.first?.phase == .failed("sbatch: error: invalid partition") }
        XCTAssertTrue(store.activeRuns.isEmpty)
    }

    func testFinishedCommandWithNoWayToIdentifyTheMachineFails() async throws {
        let store = isolatedStore(AppState(isolatedForTesting: true))
        store.request(MachineLauncher(name: "silent", command: "true"))
        try await waitFor {
            if case .failed = store.runs.first?.phase { return true }
            return false
        }
    }

    func testStopEndsTheLocalCommandAndOneRequestPerLauncherAtATime() async throws {
        let store = isolatedStore(AppState(isolatedForTesting: true))
        let launcher = MachineLauncher(name: "slow", command: "sleep 30", machinePattern: "slow-*")
        store.request(launcher)
        store.request(launcher)
        XCTAssertEqual(store.runs.count, 1)
        let run = try XCTUnwrap(store.runs.first)
        store.stop(run)
        XCTAssertEqual(store.runs.first?.phase, .stopped)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(store.runs.first?.phase, .stopped, "the exit of a stopped command must not revive it")
    }

    func testBabelPresetUsesTheBundledSlurmLauncher() {
        let preset = MachineLauncher.babelPreset()
        XCTAssertTrue(preset.command.hasPrefix("\"$ARGUS_LAUNCHERS/slurm-node\" babel up "))
        XCTAssertTrue(preset.command.contains("--time=3-00:00:00"))
        XCTAssertEqual(preset.machinePattern, "babel-*")
    }

    func testPresetCommandRunsTheBundledScriptWithItsOptions() async throws {
        // A stand-in slurm-node in a directory with a space, to prove quoting.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus launchers \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("slurm-node")
        try "#!/bin/bash\necho \"host=$1 args=$#\"\necho ARGUS_MACHINE=babel-test-1\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let store = isolatedStore(AppState(isolatedForTesting: true))
        store.launcherDirectory = dir
        store.request(.babelPreset())
        try await waitFor { store.runs.first?.phase == .waitingForMachine }
        XCTAssertEqual(store.runs.first?.lastLine, "host=babel args=8")
        XCTAssertEqual(store.runs.first?.announcedMachine, "babel-test-1")
    }

    /// No network: discovery is driven by the test through `app.machines`.
    private func isolatedStore(_ app: AppState) -> MachineLauncherStore {
        let store = MachineLauncherStore()
        store.attach(app)
        store.discover = {}
        return store
    }

    private func waitFor(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
