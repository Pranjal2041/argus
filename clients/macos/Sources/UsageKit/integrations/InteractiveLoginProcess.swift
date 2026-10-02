import Foundation
import Darwin

@available(macOS 14.0, *)
enum LoginProcessEvent: Sendable { case output(Data), exited(Int32) }

@available(macOS 14.0, *)
protocol LoginProcessServing: AnyObject, Sendable {
    var events: AsyncThrowingStream<LoginProcessEvent, Error> { get }
    func start() throws
    func sendCode(_ code: String) throws
    func cancel()
    func close() async
}

/// A private prompt terminal, never attached to a broker/session/viewer. No shell
/// is started and no global input is sent. Its only input is one user-provided
/// sign-in code plus protocol replies requested by this owned child process.
@available(macOS 14.0, *)
final class InteractiveLoginProcess: LoginProcessServing, @unchecked Sendable {
    let events: AsyncThrowingStream<LoginProcessEvent, Error>
    private let continuation: AsyncThrowingStream<LoginProcessEvent, Error>.Continuation
    private let process = Process()
    private let lock = NSLock()
    private var master: FileHandle?
    private var cancelled = false
    private var started = false
    private var timeout: DispatchWorkItem?
    private let timeoutSeconds: Double

    init(executable: String, arguments: [String], environment: [String: String], timeout: Double = 600) {
        let stream = AsyncThrowingStream<LoginProcessEvent, Error>.makeStream()
        events = stream.stream; continuation = stream.continuation
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = UsageProcessEnvironment.make(overrides: environment.merging(["TERM": "dumb", "NO_COLOR": "1"]) { _, new in new })
        process.currentDirectoryURL = URL(fileURLWithPath: environment["HOME"] ?? NSTemporaryDirectory(), isDirectory: true)
        timeoutSeconds = timeout
    }

    func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !started, !cancelled else { throw CancellationError() }
        var leader: Int32 = -1, follower: Int32 = -1
        var size = winsize(ws_row: 24, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&leader, &follower, nil, nil, &size) == 0 else {
            throw IntegrationError.unavailable("Could not open the private sign-in prompt. Try again.")
        }
        var settings = termios()
        if tcgetattr(follower, &settings) == 0 {
            settings.c_lflag &= ~tcflag_t(ECHO)
            _ = tcsetattr(follower, TCSANOW, &settings)
        }
        let terminal = FileHandle(fileDescriptor: leader, closeOnDealloc: true)
        let childTerminal = FileHandle(fileDescriptor: follower, closeOnDealloc: true)
        process.standardInput = childTerminal; process.standardOutput = childTerminal; process.standardError = childTerminal
        do { try process.run() }
        catch {
            try? terminal.close(); try? childTerminal.close()
            throw IntegrationError.unavailable("Could not launch the provider's sign-in command. Check its executable in Connections.")
        }
        started = true; master = terminal
        try? childTerminal.close()
        let deadline = DispatchWorkItem { [weak self] in
            self?.continuation.finish(throwing: IntegrationError.authentication("This sign-in expired. Start a new sign-in."))
            self?.cancel()
        }
        timeout = deadline
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds, execute: deadline)
        DispatchQueue.global(qos: .utility).async { [self] in
            var protocolState = LoginTerminalProtocol(), bytes = 0
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                // FileHandle.read(upToCount:) can wait for the requested byte
                // count on a PTY. One read(2) delivers a short prompt immediately
                // so code entry never depends on filling a capture buffer.
                let count = Darwin.read(terminal.fileDescriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                let chunk = Data(buffer.prefix(count))
                bytes += chunk.count
                if bytes > 8_000_000 { continuation.finish(throwing: IntegrationError.invalidResponse("The sign-in prompt exceeded its response limit.")); cancel(); break }
                let reply = protocolState.receive(chunk)
                if !reply.isEmpty { try? write(reply) }
                continuation.yield(.output(chunk))
            }
            process.waitUntilExit()
            lock.lock()
            master = nil; timeout?.cancel(); timeout = nil
            let wasCancelled = cancelled
            lock.unlock()
            try? terminal.close()
            if wasCancelled { continuation.finish(throwing: CancellationError()) }
            else { continuation.yield(.exited(process.terminationStatus)); continuation.finish() }
        }
    }

    func sendCode(_ code: String) throws {
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4096,
              value.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }) else {
            throw IntegrationError.authentication("Paste the complete sign-in code, without extra lines or spaces.")
        }
        try write(Data((value + "\r").utf8))
    }

    private func write(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard let master, !cancelled, process.isRunning else { throw CancellationError() }
        try master.write(contentsOf: data)
    }

    func cancel() {
        lock.lock()
        cancelled = true; timeout?.cancel(); timeout = nil
        let running = started && process.isRunning
        lock.unlock()
        continuation.finish(throwing: CancellationError())
        if running {
            signalOwnedProcess(SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
                if process.isRunning { signalOwnedProcess(SIGKILL) }
            }
        }
    }

    private func signalOwnedProcess(_ signal: Int32) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        if getpgid(pid) == pid { kill(-pid, signal) } else { kill(pid, signal) }
    }

    func close() async {
        cancel()
        await Task.detached { [self] in
            let didStart = lock.withLock { started }
            if didStart { process.waitUntilExit() }
        }.value
    }
}

/// Handles fragmented terminal capability queries only. This is not a command
/// injection facility and is not installed in user terminals or tmux brokers.
@available(macOS 14.0, *)
struct LoginTerminalProtocol {
    private var escape: [UInt8] = []
    mutating func receive(_ data: Data) -> Data {
        var replies = Data()
        for byte in data {
            if byte == 0x1b { escape = [byte]; continue }
            guard !escape.isEmpty else { continue }
            escape.append(byte)
            if escape.count == 2 {
                if byte != 0x5b { escape = [] }
                continue
            }
            if (0x40...0x7e).contains(byte) {
                let reply: String
                switch String(decoding: escape, as: UTF8.self) {
                case "\u{1b}[6n": reply = "\u{1b}[1;1R"
                case "\u{1b}[5n": reply = "\u{1b}[0n"
                case "\u{1b}[c", "\u{1b}[0c": reply = "\u{1b}[?1;2c"
                case "\u{1b}[?u": reply = "\u{1b}[?0u"
                default: reply = ""
                }
                replies.append(Data(reply.utf8)); escape = []
            } else if escape.count > 64 { escape = [] }
        }
        return replies
    }
}

@available(macOS 14.0, *)
enum UsageProcessEnvironment {
    static func make(overrides: [String: String], inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let environment: [String: String]
        if overrides["HOME"] != nil {
            // An isolated profile cannot inherit ambient provider tokens or
            // configuration overrides that select another account.
            let allowed: Set<String> = ["PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TZ", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy"]
            environment = inherited.filter { allowed.contains($0.key) }
        } else {
            environment = inherited.filter { !($0.key.hasSuffix("API_KEY") || $0.key.hasSuffix("TOKEN_SECRET") || $0.key.hasSuffix("TOKEN_ID")) }
        }
        return environment.merging(overrides.merging(["NO_COLOR": "1"]) { _, new in new }) { _, new in new }
    }
}
