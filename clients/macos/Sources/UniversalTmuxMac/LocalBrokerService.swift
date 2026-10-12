import Foundation
import ArgusProtocol

/// One launchd installation contract for both the local broker and its clients.
/// One-shot reconcilers use StartInterval; long-running workers use KeepAlive.
struct LaunchAgentService {
    let label: String
    let arguments: [String]
    var environment: [String: String] = [:]
    var keepAlive = false
    var interval: Int? = nil
    let logName: String

    func propertyList(logs: URL) -> [String: Any] {
        var result: [String: Any] = [
            "Label": label, "ProgramArguments": arguments, "RunAtLoad": true,
            "ProcessType": "Background", "ThrottleInterval": 15,
            "StandardOutPath": logs.appendingPathComponent(logName).path,
            "StandardErrorPath": logs.appendingPathComponent(logName).path,
        ]
        if keepAlive { result["KeepAlive"] = true }
        if let interval { result["StartInterval"] = interval }
        if !environment.isEmpty { result["EnvironmentVariables"] = environment }
        return result
    }

    func ensureRunning(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        uid: UInt32 = getuid(),
        run: ([String]) throws -> Int32 = LaunchAgentService.launchctl
    ) throws {
        let directory = home.appendingPathComponent("Library/LaunchAgents")
        let logs = home.appendingPathComponent("Library/Logs/Argus")
        let file = directory.appendingPathComponent(label + ".plist")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: propertyList(logs: logs), format: .xml, options: 0)
        let changed = (try? Data(contentsOf: file)) != data
        if changed { try data.write(to: file, options: .atomic) }
        let domain = "gui/\(uid)"
        if changed { _ = try run(["bootout", domain + "/" + label]) }
        if try run(["print", domain + "/" + label]) != 0 {
            // The app and login worker may reconcile concurrently. Another
            // caller winning registration is success, not a startup failure.
            guard try run(["bootstrap", domain, file.path]) == 0
                    || run(["print", domain + "/" + label]) == 0 else {
                throw ArgusFailure("service_start_failed", "Background service \(label) could not start.")
            }
        }
    }

    private static func launchctl(_ args: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

enum LocalBrokerServiceLauncher {
    static let label = "dev.universaltmux.broker"

    static func specification(
        home: URL,
        resources: URL?,
        environment: [String: String],
        executable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) throws -> LaunchAgentService {
        let utHome = environment["UT_HOME"] ?? home.appendingPathComponent(".universal-tmux").path
        let broker = environment["UT_BROKER"] ?? URL(fileURLWithPath: utHome).appendingPathComponent("ut-broker").path
        let candidates = [environment["UT_CLI"], resources?.appendingPathComponent("ut").path,
                          URL(fileURLWithPath: utHome).appendingPathComponent("ut").path].compactMap { $0 }
        guard let launcher = candidates.first(where: executable), executable(broker) else {
            throw ArgusFailure("broker_not_installed", "The local ut launcher or ut-broker executable is missing.")
        }
        var values = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                      "UT_HOME": utHome, "UT_BROKER": broker]
        // Persist configuration, never credentials such as TS_AUTHKEY. The
        // launcher reads its existing private credential store at runtime.
        for key in ["UT_STATE_DIR", "UT_LAB_ROOT", "UT_BACKUP_ROOT", "UT_LOCAL_DIR",
                    "UT_PORT", "UT_LOCAL_PORT", "UT_MACHINE_ID", "UT_TAILSCALE_BIN"] {
            if let value = environment[key], !value.isEmpty { values[key] = value }
        }
        return LaunchAgentService(
            label: label,
            arguments: [launcher, "-L", environment["UT_TMUX_SOCKET"] ?? "ut", "--broker-only"],
            environment: values, interval: 15, logName: "broker-service.log"
        )
    }

    static func ensureRunning() throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let service = try specification(
            home: FileManager.default.homeDirectoryForCurrentUser,
            resources: Bundle.main.resourceURL,
            environment: ProcessInfo.processInfo.environment
        )
        try service.ensureRunning()
    }
}
