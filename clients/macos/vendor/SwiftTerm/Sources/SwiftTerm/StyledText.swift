//
//  StyledText.swift
//  SwiftTerm
//
//  A lossless, read-only text snapshot for consumers that need to reproduce
//  terminal output outside the cell renderer (for example, print/PDF views).
//

import Foundation

/// A run of terminal characters that share the same visual attributes and link.
public struct StyledTerminalRun: Equatable {
    public let text: String
    public let attribute: Attribute
    public let link: String?

    public init(text: String, attribute: Attribute, link: String?) {
        self.text = text
        self.attribute = attribute
        self.link = link
    }
}

/// One visual grid row. `isWrapped` records whether this row continues the
/// preceding logical line; consumers may preserve the grid or reflow prose.
public struct StyledTerminalLine: Equatable {
    public let runs: [StyledTerminalRun]
    public let isWrapped: Bool

    public init(runs: [StyledTerminalRun], isWrapped: Bool) {
        self.runs = runs
        self.isWrapped = isWrapped
    }

    public var text: String { runs.map(\.text).joined() }
}

/// A bounded snapshot of terminal rows with the same attributes SwiftTerm uses
/// to draw them. Unlike `getText`, this does not discard ANSI color, emphasis,
/// cell backgrounds, hyperlinks, or row-wrap metadata.
public struct StyledTerminalText: Equatable {
    public let columns: Int
    public let lines: [StyledTerminalLine]

    public init(columns: Int, lines: [StyledTerminalLine]) {
        self.columns = columns
        self.lines = lines
    }

    public var text: String { lines.map(\.text).joined(separator: "\n") }
}

public extension Terminal {
    /// Styled rows from the tail of the currently displayed buffer, including
    /// scrollback. The visual rows are deliberately not joined: preserving their
    /// cell geometry is what keeps terminal-rendered tables and aligned output
    /// intact in downstream views.
    func getStyledText(maxVisualLines: Int = 400) -> StyledTerminalText {
        let source = displayBuffer
        var end = source.lines.count

        // A terminal buffer keeps unused rows below the cursor. Find the last
        // painted row *before* applying the cap; otherwise a short request can
        // select only allocation blanks and miss the actual tail entirely.
        while end > 0 {
            let row = styledLine(source.lines[end - 1], startCol: 0, endCol: -1)
            if !row.runs.isEmpty { break }
            end -= 1
        }
        let start = max(0, end - max(0, maxVisualLines))
        let rows = (start..<end).map { styledLine(source.lines[$0], startCol: 0, endCol: -1) }
        return StyledTerminalText(columns: source.cols, lines: rows)
    }

    /// Styled text for a buffer-relative selection. `end` is exclusive, matching
    /// SwiftTerm's plain selection extraction.
    func getStyledText(start: Position, end: Position) -> StyledTerminalText {
        let source = displayBuffer
        var lower = start
        var upper = end
        if Position.compare(lower, upper) == .after { swap(&lower, &upper) }
        guard Position.compare(lower, upper) != .equal, source.lines.count > 0 else {
            return StyledTerminalText(columns: source.cols, lines: [])
        }

        lower.row = min(max(0, lower.row), source.lines.count - 1)
        upper.row = min(max(0, upper.row), source.lines.count - 1)
        var rows: [StyledTerminalLine] = []
        for row in lower.row...upper.row {
            let startCol = row == lower.row ? lower.col : 0
            let endCol = row == upper.row ? upper.col : -1
            rows.append(styledLine(source.lines[row], startCol: startCol, endCol: endCol))
        }
        return StyledTerminalText(columns: source.cols, lines: trimmingTrailingEmptyRows(rows))
    }

    private func styledLine(_ line: BufferLine, startCol: Int, endCol: Int) -> StyledTerminalLine {
        let cells = line.getData()
        let start = min(max(0, startCol), cells.count)
        var end = endCol < 0 ? cells.count : min(max(start, endCol), cells.count)

        // Match what the terminal actually paints: code-zero cells inside a row
        // are spaces, but unused cells after the last visible glyph/background
        // are not part of the document. `hasContent` includes styled blank cells,
        // so colored table/header backgrounds survive this trim.
        while end > start, !line.hasContent(index: end - 1) { end -= 1 }

        var runs: [StyledTerminalRun] = []
        var runText = ""
        var runAttribute: Attribute?
        var runLink: String?

        func flush() {
            guard !runText.isEmpty, let attribute = runAttribute else { return }
            runs.append(StyledTerminalRun(text: runText, attribute: attribute, link: runLink))
            runText = ""
        }

        var column = start
        while column < end {
            let cell = cells[column]
            // Width-zero cells following a wide glyph occupy a grid column but
            // have no independent character. Emitting them would add a fake space.
            if column > 0, cell.width == 0, cells[column - 1].width == 2 {
                column += 1
                continue
            }

            let link = hyperlinkTarget(from: cell.getPayload() as? String)
            if runAttribute != cell.attribute || runLink != link {
                flush()
                runAttribute = cell.attribute
                runLink = link
            }
            if cell.attribute.style.contains(.invisible) || cell.code == 0 {
                runText.append(" ")
            } else {
                runText.append(getCharacter(for: cell))
            }
            column += 1
        }
        flush()
        return StyledTerminalLine(runs: runs, isWrapped: line.isWrapped)
    }

    /// OSC 8 payloads are stored as `params;URL`; downstream document renderers
    /// need the target, not SwiftTerm's transport representation.
    private func hyperlinkTarget(from payload: String?) -> String? {
        guard let payload else { return nil }
        let parts = payload.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    private func trimmingTrailingEmptyRows(_ rows: [StyledTerminalLine]) -> [StyledTerminalLine] {
        var result = rows
        while result.last?.runs.isEmpty == true { result.removeLast() }
        return result
    }
}

#if os(macOS) || os(iOS) || os(visionOS)
public extension TerminalView {
    /// Styled counterpart to `getSelection()`.
    func getStyledSelection() -> StyledTerminalText? {
        guard selection.active else { return nil }
        return terminal.getStyledText(start: selection.start, end: selection.end)
    }

    /// Resolve a cell attribute through this view's active palette, including
    /// true color, inverse, bold-bright mapping, and dim blending. This is the
    /// same attribute dictionary used by SwiftTerm's native renderer.
    func resolvedAttributes(for attribute: Attribute) -> [NSAttributedString.Key: Any] {
        getAttributes(attribute, withUrl: false) ?? [:]
    }
}
#endif
