import AppKit
import SwiftTerm

// The activity journal: an append-only, local, keep-forever record of the
// moments the user engaged with their fleet — what they saw, what they said,
// and small structured references to everything else (statuses, runs, todos,
// workflows, git reviews). One JSONL file per day under
// ~/Library/Application Support/Argus/journal/. This is the DATA layer only;
// intelligence (weekly reports etc.) reads these files later.
//
// All calls happen on the main thread (UI hooks); file writes hop to a serial
// utility queue. Every entry point checks the enable flag, so switching the
// journal off in Settings stops both capture and writes.
final class ActivityJournal {
    static let shared = ActivityJournal()

    static var dirURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Argus/journal", isDirectory: true)
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "ut.journal.enabled") as? Bool ?? true
    }
    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "ut.journal.enabled")
    }

    /// Resolve a machineID to its display name / a session to its cwd — set once
    /// by AppState. Called on the main thread at event time.
    var nameResolver: ((String) -> String?)?
    var folderResolver: ((String, String) -> String?)?

    private let q = DispatchQueue(label: "ut.journal", qos: .utility)

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.pauseDwell() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.resumeDwell() }
    }

    // MARK: writing

    func log(_ kind: String, _ fields: [String: Any], date: Date = Date()) {
        guard Self.isEnabled else { return }
        var f = fields
        if let mid = f["machineID"] as? String, f["machine"] == nil, let n = nameResolver?(mid) {
            f["machine"] = n
        }
        guard let line = journalLine(kind: kind, fields: f, date: date) else { return }
        q.async {
            let dir = Self.dirURL
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(journalDayFile(date))
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: line)
            } else {
                try? line.write(to: url)
            }
        }
    }

    /// The standard identity fields for a session-scoped event.
    func ctx(_ ref: SessionRef) -> [String: Any] {
        var f: [String: Any] = ["machineID": ref.machineID, "session": ref.session]
        if let folder = folderResolver?(ref.machineID, ref.session), !folder.isEmpty {
            f["folder"] = folder
        }
        return f
    }

    // MARK: dwell — silent attention

    // A "viewed" event fires when the user sat on a session ≥ 20s without typing
    // into it (typing already marks engagement via the utterance itself).
    private var focusRef: SessionRef?
    private var focusStart: Date?
    private var typedDuringFocus = false

    func selectionChanged(to ref: SessionRef?) {
        closeDwell()
        focusRef = ref
        focusStart = ref == nil ? nil : Date()
        typedDuringFocus = false
    }

    func markTyped(_ ref: SessionRef) {
        if ref == focusRef { typedDuringFocus = true }
    }

    private func closeDwell() {
        guard Self.isEnabled, let ref = focusRef, let t0 = focusStart else { return }
        let secs = Int(Date().timeIntervalSince(t0))
        if secs >= 20 && !typedDuringFocus {
            var f = ctx(ref)
            f["dwellSec"] = secs
            log("viewed", f, date: t0)
        }
    }

    private func pauseDwell() {
        closeDwell()
        focusStart = nil
    }

    private func resumeDwell() {
        if focusRef != nil {
            focusStart = Date()
            typedDuringFocus = false
        }
    }
}

// MARK: - Utterances (one per pane, owned by PaneConn)

/// Coalesces a pane's keystrokes into utterances and journals each one with the
/// screen as it looked when the user STARTED typing (the context they decided
/// against), the text they sent, and — some minutes later — an "outcome"
/// snapshot pairing the input with what came of it.
final class UtteranceSession {
    var ref: SessionRef?

    private weak var view: TerminalView?
    private var parser = UtteranceParser()
    private var active = false
    private var id = ""
    private var saw: [String] = []
    private var started = Date()
    private var idleWork: DispatchWorkItem?
    private var outcomeWork: DispatchWorkItem?

    static let idleGap: TimeInterval = 8        // silence that ends an utterance
    static let echoDelay: TimeInterval = 1.2    // wait for the pane to echo before the secret check
    static let outcomeDelay: TimeInterval = 480 // input → consequence pairing snapshot

    func feed(_ bytes: [UInt8], view v: TerminalView) {
        guard ActivityJournal.isEnabled, let ref else { return }
        view = v
        if !active {
            active = true
            id = UUID().uuidString.lowercased()
            saw = Self.tail(v, max: 100)   // BEFORE these keystrokes echo back
            started = Date()
            parser = UtteranceParser()
        }
        ActivityJournal.shared.markTyped(ref)
        let ended = parser.feed(bytes)
        idleWork?.cancel()
        if ended {
            finalize()
        } else {
            let w = DispatchWorkItem { [weak self] in self?.finalize() }
            idleWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleGap, execute: w)
        }
    }

    /// Ends the current utterance (Enter, idle, pane switch, or teardown).
    func finalize() {
        guard active else { return }
        active = false
        idleWork?.cancel()
        parser.flushPending()
        guard let ref, !parser.isEmpty else { return }
        let said = String(parser.said.prefix(4000))
        let keys = parser.keys
        // Zero-signal guard: stray whitespace with no semantic keys (a space to
        // nudge a pager, an accidental tap) is noise, not an interaction.
        if said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && keys.isEmpty { return }
        let mySaw = saw, myID = id, t0 = started
        let v = view
        // Give the pane a beat to echo, then apply the secret rule and write.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.echoDelay) { [weak v] in
            var f = ActivityJournal.shared.ctx(ref)
            f["id"] = myID
            f["saw"] = mySaw
            if !keys.isEmpty { f["keys"] = keys }
            if !said.isEmpty {
                let tail = v.map { Self.tail($0, max: 30).joined(separator: "\n") } ?? ""
                if echoConfirms(said: said, tail: tail) {
                    f["said"] = said
                } else {
                    // Never echoed → the pane treated it as secret. So do we.
                    f["redacted"] = true
                    f["saidChars"] = said.count
                }
            }
            ActivityJournal.shared.log("utterance", f, date: t0)
        }
        // One outcome snapshot per pane; a newer utterance supersedes a pending one.
        outcomeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard ActivityJournal.isEnabled, let self, let v = self.view else { return }
            var f = ActivityJournal.shared.ctx(ref)
            f["of"] = myID
            f["saw"] = Self.tail(v, max: 80)
            ActivityJournal.shared.log("outcome", f)
        }
        outcomeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.outcomeDelay, execute: w)
    }

    /// The pane's content as the user sees it: the visible screen plus up to
    /// `max` logical lines of scrollback above it. getText joins soft-wrapped
    /// rows, so lines read the way copy/paste would produce them.
    static func tail(_ v: TerminalView, max lines: Int) -> [String] {
        let t = v.getTerminal()
        let top = Swift.max(0, t.buffer.yDisp - lines)
        let text = t.getText(
            start: Position(col: 0, row: top),
            end: Position(col: Swift.max(0, t.cols - 1), row: t.buffer.yDisp + t.rows - 1))
        var ls = text.components(separatedBy: "\n").map { String($0.prefix(400)) }
        while let l = ls.last, l.trimmingCharacters(in: .whitespaces).isEmpty { ls.removeLast() }
        if ls.count > lines { ls.removeFirst(ls.count - lines) }
        return ls
    }
}
