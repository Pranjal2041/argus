import Foundation

/// A flight recorder for Argus-local main-thread stalls.
///
/// CrashReporter cannot help with a force-quit beachball: there is no exception
/// and therefore no `.ips`. A background heartbeat detects a main queue that has
/// not run for two seconds and asks macOS `sample` to capture the real stack while
/// it is still stuck. Captures stay local and rotate automatically.
final class MainThreadStallMonitor {
    static let shared = MainThreadStallMonitor()

    private let queue = DispatchQueue(label: "dev.universaltmux.stall-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pingOutstanding = false
    private var pingSentAt: UInt64 = 0
    private var startedAt: UInt64 = 0
    private var lastCaptureAt: UInt64 = 0

    private static let stallNanoseconds: UInt64 = 2_000_000_000
    private static let warmupNanoseconds: UInt64 = 10_000_000_000
    private static let cooldownNanoseconds: UInt64 = 120_000_000_000

    private init() {}

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.startedAt = DispatchTime.now().uptimeNanoseconds
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .seconds(1), repeating: .milliseconds(500), leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        if !pingOutstanding {
            pingOutstanding = true
            pingSentAt = now
            DispatchQueue.main.async { [weak self] in
                self?.queue.async { [weak self] in self?.pingOutstanding = false }
            }
            return
        }

        guard now - startedAt >= Self.warmupNanoseconds,
              now - pingSentAt >= Self.stallNanoseconds,
              lastCaptureAt == 0 || now - lastCaptureAt >= Self.cooldownNanoseconds else { return }
        lastCaptureAt = now
        captureSample()
    }

    private func captureSample() {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Argus/Hangs", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let path = dir.appendingPathComponent("main-thread-stall-\(formatter.string(from: Date())).sample.txt")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [
            String(ProcessInfo.processInfo.processIdentifier), "5", "1", "-mayDie", "-file", path.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? "sample launch failed: \(error)\n".write(to: path, atomically: true, encoding: .utf8)
        }
        rotate(in: dir, keeping: 14)
    }

    private func rotate(in directory: URL, keeping limit: Int) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return }
        let ordered = files.filter { $0.lastPathComponent.hasPrefix("main-thread-stall-") }.sorted {
            let lhs = (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }
        for stale in ordered.dropFirst(limit) { try? FileManager.default.removeItem(at: stale) }
    }
}
