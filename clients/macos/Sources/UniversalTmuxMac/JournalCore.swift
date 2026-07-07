import Foundation

// Pure logic for the activity journal (no AppKit / SwiftTerm imports, so a
// throwaway SwiftPM harness can compile just this file and test it directly).
//
// The journal is attention-gated: raw text is captured only at moments the user
// engages (typing, dwelling), everything else is small structured references
// into stores that already exist (git, broker history, W&B, todo boards).

// MARK: - JSONL encoding

private let journalISO: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let journalDay: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

/// "2026-07-02.jsonl" in the user's local calendar (a "day" means their day).
func journalDayFile(_ date: Date = Date()) -> String {
    journalDay.string(from: date) + ".jsonl"
}

/// One JSONL line: the fields plus ts / kind / v. Nil if fields aren't JSON-safe.
func journalLine(kind: String, fields: [String: Any], date: Date = Date()) -> Data? {
    var obj = fields
    obj["ts"] = journalISO.string(from: date)
    obj["kind"] = kind
    obj["v"] = 1
    guard JSONSerialization.isValidJSONObject(obj),
          let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    else { return nil }
    return d + Data([0x0a])
}

// MARK: - Utterance parsing

/// Accumulates one "utterance" — a burst of keystrokes ending with Enter or an
/// idle gap. Printable bytes build `said` (backspace edits it, so the record is
/// what was ultimately sent, not the keystroke log). Semantic control keys are
/// summarized in `keys` (↑↓←→ ⏎ ⇥ ⎋ ^C…). Terminal chatter that isn't the user
/// speaking — SGR mouse reports, focus events, unknown CSI — is dropped.
/// Bracketed paste is honored: Enter inside a paste is a newline, not an end.
struct UtteranceParser {
    private(set) var saidBytes = Data()
    private(set) var keys = ""
    private var esc = false
    private var csiActive = false
    private var csi = Data()
    private var ss3 = false
    private var inPaste = false

    var said: String { String(decoding: saidBytes, as: UTF8.self) }
    var isEmpty: Bool { saidBytes.isEmpty && keys.isEmpty }

    /// Feed raw input bytes; true means "Enter pressed outside a paste" — finalize.
    mutating func feed(_ bytes: [UInt8]) -> Bool {
        var finalize = false
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            i += 1
            if csiActive {
                csi.append(b)
                if b >= 0x40 && b <= 0x7e { endCSI() }
                continue
            }
            if ss3 { ss3 = false; continue }
            if esc {
                esc = false
                if b == UInt8(ascii: "[") { csiActive = true; csi = Data(); continue }
                if b == UInt8(ascii: "O") { ss3 = true; continue }
                keys += "⎋"
                i -= 1   // reprocess b on its own
                continue
            }
            switch b {
            case 0x1b: esc = true
            case 0x0d, 0x0a:
                if inPaste { saidBytes.append(0x0a) } else { keys += "⏎"; finalize = true }
            case 0x7f, 0x08: dropLastChar()
            case 0x09: keys += "⇥"
            case 0x03: keys += "^C"
            case 0x04: keys += "^D"
            case 0x1a: keys += "^Z"
            case 0x00..<0x20: break
            default: saidBytes.append(b)
            }
        }
        return finalize
    }

    /// A dangling ESC at end-of-input (the user pressed the Esc key).
    mutating func flushPending() {
        if esc { esc = false; keys += "⎋" }
    }

    private mutating func endCSI() {
        defer { csiActive = false }
        guard let final = csi.last else { return }
        let body = String(decoding: csi.dropLast(), as: UTF8.self)
        if final == UInt8(ascii: "~") {
            if body == "200" { inPaste = true; return }
            if body == "201" { inPaste = false; return }
        }
        // Mouse reports and focus in/out are the terminal talking, not the user.
        if body.hasPrefix("<") || final == UInt8(ascii: "M") { return }
        switch final {
        case UInt8(ascii: "A"): keys += "↑"
        case UInt8(ascii: "B"): keys += "↓"
        case UInt8(ascii: "C"): keys += "→"
        case UInt8(ascii: "D"): keys += "←"
        default: break
        }
    }

    private mutating func dropLastChar() {
        guard !saidBytes.isEmpty else { return }
        var n = saidBytes.count - 1
        while n > 0 && (saidBytes[n] & 0xc0) == 0x80 { n -= 1 }
        saidBytes.removeSubrange(n..<saidBytes.count)
    }
}

