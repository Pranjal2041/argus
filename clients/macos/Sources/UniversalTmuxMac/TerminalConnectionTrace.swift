import Foundation

/// A small, bounded flight recorder for terminal-selection and WebSocket lifecycle
/// bugs. Unified logging hides useful fields when Argus is launched normally, so
/// these events are kept as JSONL in ~/Library/Logs/Argus. The current and previous
/// 4 MiB files are enough to reconstruct a failure without growing forever.
enum TerminalConnectionTrace {
    private static let writer = DispatchQueue(label: "dev.universaltmux.connection-trace", qos: .utility)
    private static let maxBytes: UInt64 = 4 * 1024 * 1024

    static let logURL: URL = {
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        if isTesting {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ArgusTests-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent("terminal-connections.jsonl")
        }
        let base = (try? FileManager.default.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library")
        let directory = base.appendingPathComponent("Logs/Argus", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("terminal-connections.jsonl")
    }()

    static func record(_ event: String, _ fields: [String: Any] = [:]) {
        var payload = fields
        payload["event"] = event
        payload["ts"] = Date().timeIntervalSince1970
        payload["pid"] = ProcessInfo.processInfo.processIdentifier
        guard JSONSerialization.isValidJSONObject(payload),
              var data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else { return }
        data.append(0x0a)
        writer.async { append(data) }
    }

    /// Used by diagnostics/tests that need every queued event on disk before reading.
    static func flush() { writer.sync {} }

    private static func append(_ data: Data) {
        let fm = FileManager.default
        let size = ((try? fm.attributesOfItem(atPath: logURL.path)[.size]) as? NSNumber)?.uint64Value ?? 0
        if size + UInt64(data.count) > maxBytes {
            let previous = logURL.deletingLastPathComponent()
                .appendingPathComponent("terminal-connections.previous.jsonl")
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: logURL, to: previous)
        }
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
        }
    }
}
