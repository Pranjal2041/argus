import Foundation

/// Terminal controls have the same meaning regardless of agent or model name.
/// Keep this grammar aligned with internal/agentstate; backend classification is
/// authoritative, while this helper only removes volatile chrome from summaries.
enum AgentTerminalChrome {
    private static let interrupt = try! NSRegularExpression(
        pattern: #"(?:\besc(?:ape)?(?:[ \t]+(?:twice|again|[0-9]+[ \t]+times))?|/stop)[ \t]+to[ \t]+interrupt\b"#,
        options: [.caseInsensitive])

    static func footerRows(_ lines: [String]) -> Set<Int> {
        Set(lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }.suffix(8))
    }

    /// Match only the footer, including physical-row wraps through a control.
    /// Mark only rows touched by the control, preserving surrounding real output.
    static func interruptRows(_ lines: [String]) -> Set<Int> {
        let footer = footerRows(lines).sorted()
        var result = Set<Int>()
        var runs: [[Int]] = []
        for row in footer {
            if let last = runs.last?.last, last + 1 == row { runs[runs.count - 1].append(row) }
            else { runs.append([row]) }
        }
        for run in runs {
            for separator in ["", " "] {
                var joined = ""
                var ranges: [(Int, NSRange)] = []
                for row in run {
                    let line = lines[row].replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
                    ranges.append((row, NSRange(location: joined.utf16.count, length: line.utf16.count)))
                    joined += line + separator
                }
                for match in interrupt.matches(in: joined, range: NSRange(joined.startIndex..., in: joined)) {
                    for (row, range) in ranges where NSIntersectionRange(match.range, range).length > 0 {
                        result.insert(row)
                    }
                }
            }
        }
        return result
    }

    /// Require composer geometry before treating text/key names as chrome.
    /// A real answer explaining "ctrl+x" or quoting "> text" is still content.
    static func editorRows(_ lines: [String]) -> Set<Int> {
        let footer = footerRows(lines).sorted()
        for row in footer.reversed() {
            let text = lines[row].trimmingCharacters(in: .whitespaces)
            guard ["❯", "❭", "›", ">"].contains(where: { text == $0 || text.hasPrefix($0 + " ") }), row > 0 else { continue }
            guard let before = footer.last(where: { $0 < row && isRule(lines[$0]) }),
                  let after = footer.first(where: { $0 > row && isRule(lines[$0]) }),
                  row - before <= 2, after - row <= 4 else { continue }
            return Set(before..<lines.count)
        }
        return []
    }

    private static func isRule(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).range(of: #"^[─━═-]{3,}"#, options: .regularExpression) != nil
    }

    static func chromeRows(_ lines: [String]) -> Set<Int> {
        let editor = editorRows(lines)
        return Set(footerRows(lines).filter { row in
            let text = lines[row].trimmingCharacters(in: .whitespaces)
            if ["❯", "❭", "›", ">"].contains(text) || isRule(text) { return true }
            guard editor.contains(row) else { return false }
            return isStatusBar(text) || ["❯", "❭", "›", ">"].contains(where: { text.hasPrefix($0 + " ") })
        })
    }

    private static func isStatusBar(_ line: String) -> Bool {
        line.range(of: #"(?i)(?:ctrl|opt|alt|shift)\+[a-z]+\s|\? for shortcuts|bypass permissions|\bcontext:\s*[0-9.]+[km]?\s*/\s*[0-9.]+[km]?\s*tokens"#,
                   options: .regularExpression) != nil
    }

    static func contentKey(_ output: String) -> Int {
        let lines = output.components(separatedBy: "\n")
        let controls = interruptRows(lines)
        let editor = editorRows(lines)
        var normalized: [String] = []
        for row in lines.indices {
            if controls.contains(row) {
                if row == 0 || !controls.contains(row - 1) { normalized.append("·working·") }
            } else if editor.contains(row) && isStatusBar(lines[row]) {
                normalized.append("·status·")
            } else {
                normalized.append(lines[row].trimmingCharacters(in: .whitespaces))
            }
        }
        return normalized.joined(separator: "\n").hashValue
    }
}
