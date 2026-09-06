import Foundation
import AppKit
import ArgusProtocol

func output<T: Encodable>(_ value: T, pretty: Bool) throws {
    var data = try ArgusWire.encoder(pretty: pretty).encode(value); data.append(10)
    FileHandle.standardOutput.write(data)
}
let raw = Array(CommandLine.arguments.dropFirst())
let json = raw.contains("--json")
var requestID = UUID().uuidString
do {
    var words: [String] = []; var options: [String: ArgusJSON] = [:]
    var actor = "cli"; var path = ArgusLocalSocket.defaultPath
    var i = 0
    let flags = Set(ArgusCommand.all.flatMap(\.flags))
    while i < raw.count {
        let arg = raw[i]; i += 1
        if arg == "--json" { continue }
        if arg == "--help" || arg == "help" || arg == "-h" {
            print("argus — local interface to the running Argus Mac app\n\nCommands:")
            for c in ArgusCommand.all where c.name != "events.poll" { print("  \(c.name.replacingOccurrences(of: ".", with: " "))  \(c.positional.map { "<\($0)>" }.joined(separator: " "))\n    \(c.summary)") }
            print("\n  app launch       Explicit background launch\n  events watch --after <cursor>\n  jobs wait <id> [--timeout <seconds>]\n\nGlobal: --json --actor <name> --request-id <id> --socket <absolute-path>\nEdits: --if-revision <revision>. Use --text-file <path|-> for text or --document-file <path|-> for JSON.\nSchemas: argus capabilities --json\nNo command activates Argus except app activate. Actor is attribution, not authentication.")
            exit(0)
        }
        if arg.hasPrefix("--") {
            let key = String(arg.dropFirst(2))
            guard options[key] == nil else { throw ArgusFailure("invalid_arguments", "Duplicate option \(arg).") }
            if flags.contains(key) { options[key] = .bool(true); continue }
            guard i < raw.count else { throw ArgusFailure("invalid_arguments", "Missing value for \(arg).") }
            let value = raw[i]; i += 1
            switch key {
            case "actor": actor = value
            case "request-id": requestID = value
            case "socket": path = value
            case "text-file", "document-file":
                let target = String(key.dropLast(5))
                guard options[target] == nil else { throw ArgusFailure("invalid_arguments", "Provide either --\(target) or --\(key), not both.") }
                let handle = value == "-" ? FileHandle.standardInput : try FileHandle(forReadingFrom: URL(fileURLWithPath: value))
                defer { if value != "-" { try? handle.close() } }
                let bytes = try handle.read(upToCount: ArgusWire.maxRequestBytes + 1) ?? Data()
                guard bytes.count <= ArgusWire.maxRequestBytes, let text = String(data: bytes, encoding: .utf8) else { throw ArgusFailure("invalid_arguments", "Input must be UTF-8 and at most 1 MiB.") }
                options[target] = .string(text)
            default: options[key] = .string(value)
            }
        } else { words.append(arg == "cc" && words.isEmpty ? "command-center" : arg) }
    }
    guard !words.isEmpty else { throw ArgusFailure("invalid_arguments", "Use argus --help to see commands.") }
    if words == ["app", "launch"] {
        guard options.isEmpty else { throw ArgusFailure("invalid_arguments", "app launch takes no options.") }
        let cli = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundledApp = cli.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = bundledApp.pathExtension == "app" ? bundledApp : URL(fileURLWithPath: "/Applications/Argus.app")
        let config = NSWorkspace.OpenConfiguration(); config.activates = false
        NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
            if let error { FileHandle.standardError.write(Data("argus: \(error.localizedDescription)\n".utf8)); exit(1) }
            try? output(ArgusResponse(id: requestID, result: .object(["launch_requested": .bool(true)])), pretty: !json)
            exit(0)
        }
        RunLoop.main.run(); exit(1)
    }
    let watch = words == ["events", "watch"]
    let waiting = words.prefix(2) == ["jobs", "wait"]
    var timeout: Double = 300
    if waiting {
        if let raw = options.removeValue(forKey: "timeout")?.string {
            guard let n = Double(raw), n.isFinite, n > 0 else { throw ArgusFailure("invalid_arguments", "Timeout must be a positive number of seconds.") }; timeout = n
        }
        words[1] = "get"
    }
    if watch { words = ["events", "poll"]; options["wait"] = .string("25") }
    let matches = ArgusCommand.all.filter { words.starts(with: $0.name.split(separator: ".").map(String.init)) }
    guard let spec = matches.max(by: { $0.name.count < $1.name.count }) else { throw ArgusFailure("unknown_command", "Unknown command. Use argus --help.") }
    let trailing = words.dropFirst(spec.name.split(separator: ".").count)
    guard trailing.count <= spec.positional.count else { throw ArgusFailure("invalid_arguments", "Too many arguments for \(spec.name).") }
    for (key, value) in zip(spec.positional, trailing) {
        guard options[key] == nil else { throw ArgusFailure("invalid_arguments", "Duplicate argument \(key).") }
        options[key] = .string(value)
    }
    try spec.validate(options)
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    repeat {
        let response = try ArgusLocalSocket.call(ArgusRequest(id: requestID, method: spec.name, params: options, actor: actor), path: path)
        if watch, response.ok, let result = response.result {
            for event in result["events"].array ?? [] { try output(event, pretty: false) }
            if let cursor = result["cursor"].string { options["after"] = .string(cursor) }
        } else if !waiting || !response.ok || ["complete", "failed", "interrupted"].contains(response.result?["state"].string ?? "") {
            try output(response, pretty: !json)
            if !response.ok { exit(response.error?.code == "conflict" ? 3 : 1) }
            if waiting && response.result?["state"].string != "complete" { exit(4) }
            if !watch { break }
        }
        if !response.ok { exit(1) }
        if waiting {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ArgusFailure("wait_timeout", "Stopped waiting; the app-owned job was not cancelled.", details: response.result ?? .null) }
            Thread.sleep(forTimeInterval: 1)
        }
    } while watch || waiting
} catch {
    let failure = (error as? ArgusFailure) ?? ArgusFailure("local_error", error.localizedDescription)
    if json { try? output(ArgusResponse(id: requestID, error: failure), pretty: false) }
    else { FileHandle.standardError.write(Data("argus: \(failure.message)\nrequest_id: \(requestID)\n".utf8)) }
    exit(failure.code == "conflict" ? 3 : 1)
}
