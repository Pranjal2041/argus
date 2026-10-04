import Foundation

/// Activity Journal capture, matching the Android client (JournalCapture.kt):
/// what you type into a terminal becomes an "utterance" event — what you said,
/// special keys, and the screen you were looking at — delivered as JSONL to the
/// Mac's `/journal/append` inbox. Text that never echoes (a password) is
/// recorded only as a character count.
@MainActor
final class JournalCapture {
    static let shared = JournalCapture()
    static let enabledKey = "argus.journal"
    private static let outboxKey = "argus.journalOutbox.v1"

    private weak var fleet: FleetStore?
    private var flushing = false
    private var flushLoop: Task<Void, Never>?

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    func attach(fleet: FleetStore) {
        self.fleet = fleet
        flushLoop?.cancel()
        flushLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                await self?.flush()
            }
        }
    }

    func recorder(machine: Machine, session: String, screenTail: @escaping () -> [String]) -> UtteranceRecorder {
        UtteranceRecorder(machine: machine, session: session, screenTail: screenTail) { [weak self] event in
            self?.enqueue(event)
        }
    }

    private func enqueue(_ event: [String: Any]) {
        guard enabled, let data = try? JSONSerialization.data(withJSONObject: event),
              let line = String(data: data, encoding: .utf8) else { return }
        var outbox = UserDefaults.standard.stringArray(forKey: Self.outboxKey) ?? []
        outbox.append(line)
        UserDefaults.standard.set(Array(outbox.suffix(200)), forKey: Self.outboxKey)
        Task { await flush() }
    }

    func flush() async {
        guard !flushing, let host = fleet?.syncHost else { return }
        let outbox = UserDefaults.standard.stringArray(forKey: Self.outboxKey) ?? []
        guard !outbox.isEmpty else { return }
        flushing = true
        defer { flushing = false }
        let body = outbox.map { $0 + "\n" }.joined()
        do {
            try await BrokerHTTP.post(host.httpBase, "journal/append", body: Data(body.utf8))
            let now = UserDefaults.standard.stringArray(forKey: Self.outboxKey) ?? []
            UserDefaults.standard.set(Array(now.dropFirst(outbox.count)), forKey: Self.outboxKey)
        } catch {
            // Kept in the outbox; retried on the next flush.
        }
    }
}

/// Turns keystrokes for one terminal into utterances. An utterance ends on
/// Enter (outside a bracketed paste), after 8 s idle, or when the pane closes.
@MainActor
final class UtteranceRecorder {
    private let machine: Machine
    private let session: String
    private let screenTail: () -> [String]
    private let emit: ([String: Any]) -> Void

    private var said = ""
    private var keys = ""
    private var saw: [String] = []
    private var started: Date?
    private var inPaste = false
    private var escape: [UInt8] = []
    private var pendingUTF8: [UInt8] = []
    private var idle: Task<Void, Never>?

    init(machine: Machine, session: String, screenTail: @escaping () -> [String], emit: @escaping ([String: Any]) -> Void) {
        self.machine = machine; self.session = session; self.screenTail = screenTail; self.emit = emit
    }

    func feed(_ bytes: ArraySlice<UInt8>) {
        if started == nil {
            started = Date()
            saw = Self.clip(screenTail())   // what you were looking at, before the echo
        }
        for b in bytes { consume(b) }
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func consume(_ b: UInt8) {
        if !escape.isEmpty || b == 0x1b {
            escape.append(b)
            handleEscape()
            return
        }
        switch b {
        case 0x0d, 0x0a:
            if inPaste { said += "\n" } else { keys += "⏎"; finish() }
        case 0x7f, 0x08:
            if !said.isEmpty { said.removeLast() }
        case 0x09: keys += "⇥"
        case 0x03: keys += "^C"
        case 0x04: keys += "^D"
        case 0x1a: keys += "^Z"
        case 0x20...0x7e: said.append(Character(UnicodeScalar(b)))
        case 0x80...0xff:
            pendingUTF8.append(b)
            if let s = String(bytes: pendingUTF8, encoding: .utf8) { said += s; pendingUTF8.removeAll() }
            else if pendingUTF8.count >= 4 { pendingUTF8.removeAll() }
        default: break
        }
    }

    /// ESC alone = Esc key; CSI arrows/paste markers are recognized; mouse,
    /// focus and other sequences are dropped.
    private func handleEscape() {
        let s = escape
        if s.count == 1 { return }
        if s[1] != UInt8(ascii: "[") && s[1] != UInt8(ascii: "O") { keys += "⎋"; escape = []; consume(s[1]); return }
        guard let last = s.last, s.count >= 3, (0x40...0x7e).contains(last) else {
            if s.count > 32 { escape = [] }
            return
        }
        let body = String(decoding: s.dropFirst(2), as: UTF8.self)
        switch body {
        case "A": keys += "↑"
        case "B": keys += "↓"
        case "C": keys += "→"
        case "D": keys += "←"
        case "200~": inPaste = true
        case "201~": inPaste = false
        default: break
        }
        escape = []
    }

    func finish() {
        idle?.cancel()
        defer { said = ""; keys = ""; saw = []; started = nil; inPaste = false }
        guard let started, !(said.trimmingCharacters(in: .whitespaces).isEmpty && keys.isEmpty) else { return }
        var event: [String: Any] = [
            "id": UUID().uuidString.lowercased(), "kind": "utterance", "v": 1, "src": "phone",
            "ts": Self.timestamp(started), "machineID": machine.id, "machine": machine.name,
            "session": session, "saw": saw,
        ]
        if !keys.isEmpty { event["keys"] = keys }
        let text = String(said.prefix(4000))
        guard !text.isEmpty else { emit(event); return }
        // Secret rule: record the text only once it has visibly echoed.
        let needle = String(Self.squash(text).suffix(12))
        Task { [weak self] in
            for delay in [1.5, 2.5, 4.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self else { return }
                if Self.squash(self.screenTail().joined(separator: "\n")).contains(needle) {
                    event["said"] = text
                    self.emit(event)
                    return
                }
            }
            event["redacted"] = true
            event["saidChars"] = text.count
            self?.emit(event)
        }
    }

    static func squash(_ s: String) -> String { String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init)) }
    static func clip(_ lines: [String]) -> [String] { Array(lines.suffix(60)).map { String($0.prefix(400)) } }
    static func timestamp(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }
}
