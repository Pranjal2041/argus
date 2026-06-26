import SwiftUI

// =============================================================================
// Rich previews for data files in the Files viewer: a collapsible JSON tree and
// a CSV/TSV table. Both are native SwiftUI (no WebView), parse off the loaded
// text, and degrade gracefully (a parse error falls back to a gentle message;
// the editor mode is always still one toolbar click away).
// =============================================================================

// MARK: - JSON value (key order PRESERVED) + a small recursive-descent parser

indirect enum JSONValue {
    case object([(String, JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(String)   // kept as text so 1.0 / 1e9 / big ints render as written
    case bool(Bool)
    case null
}

/// Parses JSON while preserving object key order (Foundation's JSONSerialization
/// returns unordered dictionaries, which scrambles a config file's preview). Caps
/// total node count so a pathological file can't hang the UI — over the cap we
/// throw and the caller falls back to the editor.
final class JSONParser {
    struct TooLarge: Error {}
    struct Bad: Error { let msg: String }

    private let chars: [Character]
    private var pos = 0
    private var count = 0
    private let cap: Int

    init(_ text: String, cap: Int = 200_000) {
        // Swift treats "\r\n" as ONE Character, so per-Character whitespace
        // handling wouldn't skip a CRLF — normalize line endings to LF first.
        let lf = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        chars = Array(lf); self.cap = cap
    }

    func parse() throws -> JSONValue {
        skipWS()
        let v = try value()
        return v
    }

    private func peek() -> Character? { pos < chars.count ? chars[pos] : nil }
    @discardableResult private func adv() -> Character? { if pos < chars.count { let c = chars[pos]; pos += 1; return c }; return nil }
    private func skipWS() { while let c = peek(), c == " " || c == "\n" || c == "\t" || c == "\r" { pos += 1 } }

    private func value() throws -> JSONValue {
        count += 1
        if count > cap { throw TooLarge() }
        skipWS()
        guard let c = peek() else { throw Bad(msg: "unexpected end of input") }
        switch c {
        case "{": return try object()
        case "[": return try array()
        case "\"": return .string(try str())
        case "t", "f": return try boolean()
        case "n": if match("null") { return .null }; throw Bad(msg: "invalid token")
        default: return try number()
        }
    }

    private func object() throws -> JSONValue {
        pos += 1 // {
        var pairs: [(String, JSONValue)] = []
        skipWS()
        if peek() == "}" { pos += 1; return .object(pairs) }
        while true {
            skipWS()
            guard peek() == "\"" else { throw Bad(msg: "expected a key") }
            let key = try str()
            skipWS()
            guard adv() == ":" else { throw Bad(msg: "expected ':'") }
            pairs.append((key, try value()))
            skipWS()
            switch adv() {
            case ",": continue
            case "}": return .object(pairs)
            default: throw Bad(msg: "expected ',' or '}'")
            }
        }
    }

    private func array() throws -> JSONValue {
        pos += 1 // [
        var items: [JSONValue] = []
        skipWS()
        if peek() == "]" { pos += 1; return .array(items) }
        while true {
            items.append(try value())
            skipWS()
            switch adv() {
            case ",": continue
            case "]": return .array(items)
            default: throw Bad(msg: "expected ',' or ']'")
            }
        }
    }

    private func str() throws -> String {
        pos += 1 // opening quote
        var out = ""
        while let c = adv() {
            if c == "\"" { return out }
            if c == "\\" {
                guard let e = adv() else { throw Bad(msg: "bad escape") }
                switch e {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "u":
                    var hex = ""
                    for _ in 0..<4 { if let h = adv() { hex.append(h) } }
                    if let code = UInt32(hex, radix: 16), let sc = Unicode.Scalar(code) { out.append(Character(sc)) }
                default: out.append(e)
                }
            } else {
                out.append(c)
            }
        }
        throw Bad(msg: "unterminated string")
    }

    private func number() throws -> JSONValue {
        var n = ""
        while let c = peek(), "0123456789+-.eE".contains(c) { n.append(c); pos += 1 }
        guard !n.isEmpty else { throw Bad(msg: "unexpected character") }
        return .number(n)
    }

    private func boolean() throws -> JSONValue {
        if match("true") { return .bool(true) }
        if match("false") { return .bool(false) }
        throw Bad(msg: "invalid token")
    }

    private func match(_ word: String) -> Bool {
        let w = Array(word)
        guard pos + w.count <= chars.count else { return false }
        for k in 0..<w.count where chars[pos + k] != w[k] { return false }
        pos += w.count
        return true
    }
}

// MARK: - JSON tree model (lazy-flattened, collapsible)

final class JNode: Identifiable {
    let id: Int  // assigned via a counter (stable + cheap; pre-order, so flatten ids are unique)
    let key: String?     // object key
    let index: Int?      // array index
    let value: JSONValue
    let depth: Int
    let children: [JNode]
    var expanded: Bool

    var isContainer: Bool { switch value { case .object, .array: return true; default: return false } }
    var childCount: Int {
        switch value { case .object(let p): return p.count; case .array(let a): return a.count; default: return 0 }
    }

    init(key: String?, index: Int?, value: JSONValue, depth: Int, expandDepth: Int, ctr: inout Int) {
        ctr += 1; id = ctr
        self.key = key; self.index = index; self.value = value; self.depth = depth
        self.expanded = depth < expandDepth
        switch value {
        case .object(let pairs):
            var kids: [JNode] = []; kids.reserveCapacity(pairs.count)
            for (k, v) in pairs { kids.append(JNode(key: k, index: nil, value: v, depth: depth + 1, expandDepth: expandDepth, ctr: &ctr)) }
            children = kids
        case .array(let items):
            var kids: [JNode] = []; kids.reserveCapacity(items.count)
            for (i, v) in items.enumerated() { kids.append(JNode(key: nil, index: i, value: v, depth: depth + 1, expandDepth: expandDepth, ctr: &ctr)) }
            children = kids
        default:
            children = []
        }
    }
}

@MainActor
final class JSONTreeModel: ObservableObject {
    @Published var root: JNode?
    @Published var error: String?
    @Published var truncated = false
    @Published private(set) var revision = 0
    private var lastText: String?

    func load(_ text: String) {
        guard text != lastText else { return }
        lastText = text
        do {
            let v = try JSONParser(text).parse()
            var ctr = 0
            self.root = JNode(key: nil, index: nil, value: v, depth: 0, expandDepth: 2, ctr: &ctr)
            self.error = nil; self.truncated = false
        } catch is JSONParser.TooLarge {
            self.root = nil; self.error = nil; self.truncated = true
        } catch let e as JSONParser.Bad {
            self.root = nil; self.error = e.msg; self.truncated = false
        } catch {
            self.root = nil; self.error = "could not parse JSON"; self.truncated = false
        }
        revision &+= 1
    }

    func toggle(_ n: JNode) { n.expanded.toggle(); revision &+= 1 }
    func setAll(_ open: Bool) { if let r = root { walk(r) { $0.expanded = open } }; revision &+= 1 }
    private func walk(_ n: JNode, _ f: (JNode) -> Void) { f(n); for c in n.children { walk(c, f) } }
}

struct JSONPreviewView: View {
    let text: String
    let fontSize: Double
    @StateObject private var model = JSONTreeModel()
    @State private var debounce: DispatchWorkItem?

    private struct Row: Identifiable { let node: JNode; var id: Int { node.id } }

    private var rows: [Row] {
        _ = model.revision
        guard let r = model.root else { return [] }
        var out: [Row] = []
        func walk(_ n: JNode) {
            out.append(Row(node: n))
            if n.isContainer, n.expanded { for c in n.children { walk(c) } }
        }
        walk(r)
        return out
    }

    var body: some View {
        Group {
            if model.truncated {
                FilePreviewNotice(symbol: "doc.text.magnifyingglass", text: "This JSON is very large — open it in the editor to view.")
            } else if let err = model.error {
                FilePreviewNotice(symbol: "exclamationmark.triangle", text: "Not valid JSON\n\(err)")
            } else if model.root != nil {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Button { model.setAll(true) } label: { Label("Expand all", systemImage: "plus.square.on.square").font(.system(size: 10)) }
                        Button { model.setAll(false) } label: { Label("Collapse", systemImage: "minus.square").font(.system(size: 10)) }
                        Spacer()
                    }
                    .buttonStyle(.plain).foregroundStyle(Flat.dim)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    Divider().overlay(Flat.hairline)
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { JSONRow(node: $0.node, fontSize: fontSize, model: model) }
                        }
                        .padding(.vertical, 6).padding(.horizontal, 4)
                    }
                }
            } else {
                FilePreviewNotice(symbol: "ellipsis", text: "Reading…")
            }
        }
        .background(Flat.bg)
        .onAppear { model.load(text) }
        .onChange(of: text) { v in
            debounce?.cancel()
            let w = DispatchWorkItem { model.load(v) }
            debounce = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
        }
    }
}

private struct JSONRow: View {
    @ObservedObject var model: JSONTreeModel
    let node: JNode
    let fontSize: Double
    init(node: JNode, fontSize: Double, model: JSONTreeModel) { self.node = node; self.fontSize = fontSize; self.model = model }

    private func mono(_ s: CGFloat) -> Font { .system(size: s, design: .monospaced) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if node.isContainer {
                Image(systemName: node.expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: CGFloat(fontSize) * 0.7, weight: .semibold)).foregroundStyle(Flat.faint).frame(width: 12)
            } else {
                Color.clear.frame(width: 12)
            }
            // key / index label
            if let k = node.key {
                Text(verbatim: "\(k):").font(mono(CGFloat(fontSize))).foregroundStyle(Theme.accent).textSelection(.enabled)
            } else if let i = node.index {
                Text(verbatim: "\(i)").font(mono(CGFloat(fontSize))).foregroundStyle(Flat.faint)
            }
            valueLabel
            Spacer(minLength: 8)
        }
        .padding(.leading, CGFloat(node.depth) * (CGFloat(fontSize) * 0.95) + 6)
        .padding(.trailing, 10).padding(.vertical, 1.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { if node.isContainer { model.toggle(node) } }
        .contextMenu { Button("Copy value") { copyValue() } }
    }

    @ViewBuilder private var valueLabel: some View {
        switch node.value {
        case .object:
            Text(verbatim: node.expanded ? "{" : "{ … } \(node.childCount)")
                .font(mono(CGFloat(fontSize))).foregroundStyle(Flat.faint)
        case .array:
            Text(verbatim: node.expanded ? "[" : "[ … ] \(node.childCount)")
                .font(mono(CGFloat(fontSize))).foregroundStyle(Flat.faint)
        case .string(let s):
            Text(verbatim: "\"\(s)\"").font(mono(CGFloat(fontSize)))
                .foregroundStyle(Color(hex: "#9ECE6A")).lineLimit(1).truncationMode(.tail).textSelection(.enabled)
        case .number(let n):
            Text(verbatim: n).font(mono(CGFloat(fontSize))).foregroundStyle(Color(hex: "#7AA2F7")).textSelection(.enabled)
        case .bool(let b):
            Text(verbatim: b ? "true" : "false").font(mono(CGFloat(fontSize))).foregroundStyle(Color(hex: "#BB9AF7")).textSelection(.enabled)
        case .null:
            Text(verbatim: "null").font(mono(CGFloat(fontSize))).foregroundStyle(Flat.faint).textSelection(.enabled)
        }
    }

    private func copyValue() {
        let s: String
        switch node.value {
        case .string(let v): s = v
        case .number(let v): s = v
        case .bool(let v): s = v ? "true" : "false"
        case .null: s = "null"
        default: s = jsonText(node.value, indent: 0)
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
    }
}

/// Re-serialize a JSONValue to pretty text (for "copy value" on a container).
func jsonText(_ v: JSONValue, indent: Int) -> String {
    let pad = String(repeating: "  ", count: indent)
    let pad2 = String(repeating: "  ", count: indent + 1)
    switch v {
    case .object(let pairs):
        if pairs.isEmpty { return "{}" }
        let body = pairs.map { "\(pad2)\"\($0.0)\": \(jsonText($0.1, indent: indent + 1))" }.joined(separator: ",\n")
        return "{\n\(body)\n\(pad)}"
    case .array(let items):
        if items.isEmpty { return "[]" }
        let body = items.map { "\(pad2)\(jsonText($0, indent: indent + 1))" }.joined(separator: ",\n")
        return "[\n\(body)\n\(pad)]"
    case .string(let s): return "\"\(s)\""
    case .number(let n): return n
    case .bool(let b): return b ? "true" : "false"
    case .null: return "null"
    }
}

// MARK: - CSV / TSV table preview

/// RFC-4180-ish CSV parser: handles quoted fields with embedded delimiters,
/// quotes ("" escape), and newlines. For TSV the delimiter is a tab.
enum DelimitedParser {
    static func parse(_ text: String, delimiter: Character, rowCap: Int = 5000) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        // Normalize line endings first: Swift's String makes "\r\n" a SINGLE
        // Character, so the per-Character row-break case below would never see a
        // bare "\n" in a CRLF file (the bug that folded the whole file into one row).
        let lf = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let chars = Array(lf)
        var i = 0
        func endField() { row.append(field); field = "" }
        func endRow() { endField(); rows.append(row); row = [] }
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 2; continue }
                    inQuotes = false; i += 1; continue
                }
                field.append(c); i += 1; continue
            }
            switch c {
            case "\"": inQuotes = true; i += 1
            case delimiter: endField(); i += 1
            case "\r": i += 1   // swallow; \n ends the row
            case "\n":
                endRow(); i += 1
                if rows.count >= rowCap { return rows }
            default: field.append(c); i += 1
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}

struct TablePreviewView: View {
    let text: String
    let isTSV: Bool
    let fontSize: Double

    @State private var header: [String] = []
    @State private var body0: [[String]] = []
    @State private var sortCol: Int? = nil
    @State private var sortAsc = true
    @State private var widths: [CGFloat] = []
    @State private var capped = false
    @State private var debounce: DispatchWorkItem?

    private func mono(_ s: CGFloat) -> Font { .system(size: s, design: .monospaced) }
    private var cols: Int { header.count }

    private var sortedRows: [[String]] {
        guard let c = sortCol, c < cols else { return body0 }
        let asc = sortAsc
        return body0.sorted { a, b in
            let x = c < a.count ? a[c] : "", y = c < b.count ? b[c] : ""
            if let nx = Double(x), let ny = Double(y), nx != ny { return asc ? nx < ny : nx > ny }
            let r = x.localizedStandardCompare(y)
            return asc ? r == .orderedAscending : r == .orderedDescending
        }
    }

    private var totalWidth: CGFloat { max(widths.reduce(0, +), 60) }
    private var colRange: [Int] { Array(0..<cols) }

    private var headerRow: some View {
        HStack(spacing: 0) { ForEach(colRange, id: \.self) { c in headerCell(c) } }
            .background(Flat.sidebar)
            .overlay(alignment: .bottom) { Rectangle().fill(Flat.hairline).frame(height: 1) }
    }

    private func rowView(_ idx: Int, _ r: [String]) -> some View {
        HStack(spacing: 0) { ForEach(colRange, id: \.self) { c in cell(c < r.count ? r[c] : "", width: width(c)) } }
            .background(idx % 2 == 0 ? Color.clear : Flat.sidebar.opacity(0.4))
    }

    var body: some View {
        Group {
            if header.isEmpty {
                FilePreviewNotice(symbol: "tablecells", text: "Empty or unparsable table")
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("\(body0.count) row\(body0.count == 1 ? "" : "s") · \(cols) column\(cols == 1 ? "" : "s")\(capped ? " (first 5,000)" : "")")
                            .font(.system(size: 10)).foregroundStyle(Flat.faint)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    Divider().overlay(Flat.hairline)
                    // Horizontal scroll holds the whole grid; the header sits ABOVE the
                    // inner vertical scroll, so it stays put while rows scroll and moves
                    // sideways with the columns. (A 2-axis scroll + pinned section header
                    // mispositioned the header — this is the robust spreadsheet layout.)
                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 0) {
                            headerRow
                            ScrollView(.vertical, showsIndicators: true) {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(sortedRows.enumerated()), id: \.offset) { idx, r in
                                        rowView(idx, r)
                                    }
                                }
                            }
                        }
                        .frame(width: totalWidth, alignment: .leading)
                    }
                }
            }
        }
        .background(Flat.bg)
        .onAppear { reparse(text) }
        .onChange(of: text) { v in
            debounce?.cancel()
            let w = DispatchWorkItem { reparse(v) }
            debounce = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
        }
    }

    private func headerCell(_ c: Int) -> some View {
        Button {
            if sortCol == c { sortAsc.toggle() } else { sortCol = c; sortAsc = true }
        } label: {
            HStack(spacing: 3) {
                Text(c < header.count ? header[c] : "").font(mono(CGFloat(fontSize) * 0.95).weight(.semibold))
                    .foregroundStyle(Flat.text).lineLimit(1)
                if sortCol == c {
                    Image(systemName: sortAsc ? "chevron.up" : "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.accent)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6).frame(width: width(c), alignment: .leading)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) { Rectangle().fill(Flat.hairline).frame(width: 1) }
    }

    private func cell(_ s: String, width: CGFloat) -> some View {
        Text(s).font(mono(CGFloat(fontSize) * 0.95)).foregroundStyle(Flat.text.opacity(0.9))
            .lineLimit(1).truncationMode(.tail)
            .textSelection(.enabled)
            .help(s.count > 24 ? s : "")   // full value on hover when the cell is truncated
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(width: width, alignment: .leading)
            .overlay(alignment: .trailing) { Rectangle().fill(Flat.hairline.opacity(0.5)).frame(width: 1) }
    }

    private func width(_ c: Int) -> CGFloat { c < widths.count ? widths[c] : 120 }

    private func reparse(_ t: String) {
        let rows = DelimitedParser.parse(t, delimiter: isTSV ? "\t" : ",")
        capped = rows.count >= 5000
        guard let head = rows.first else { header = []; body0 = []; widths = []; return }
        header = head
        body0 = Array(rows.dropFirst())
        // column widths from a sample of the body + header (monospace → ~char width)
        let charW = CGFloat(fontSize) * 0.95 * 0.62
        let sample = body0.prefix(200)
        var w = [CGFloat](repeating: 0, count: head.count)
        for c in head.indices { w[c] = CGFloat(head[c].count) }
        for r in sample { for c in 0..<min(r.count, w.count) { w[c] = max(w[c], CGFloat(r[c].count)) } }
        widths = w.map { min(360, max(60, $0 * charW + 18)) }
        sortCol = nil; sortAsc = true
    }
}

// MARK: - shared notice + small helpers

struct FilePreviewNotice: View {
    let symbol: String
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 24, weight: .light)).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Flat.bg)
    }
}

// MARK: - Get Info panel (right-click → properties)

struct FileInfoView: View {
    let entry: FileEntry
    let isLocal: Bool
    let close: () -> Void

    private var modified: String {
        guard entry.mtime > 0 else { return "—" }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(entry.mtime)))
    }
    private var sizeText: String {
        if entry.isDir { return "—" }
        if entry.size < 1024 { return "\(entry.size) bytes" }
        return "\(byteSize(entry.size))  (\(grouped(entry.size)) bytes)"
    }
    private func grouped(_ n: Int64) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: entry.isDir ? "folder.fill" : iconForFile(entry.name))
                    .font(.system(size: 30)).foregroundStyle(Theme.accent).frame(width: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                    Text(friendlyKind(entry)).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }.padding(16)
            Divider().overlay(Flat.hairline)
            VStack(alignment: .leading, spacing: 10) {
                infoRow("Size", sizeText)
                infoRow("Modified", modified)
                if !entry.mode.isEmpty { infoRow("Permissions", entry.mode, mono: true) }
                if entry.symlink == true, let t = entry.target { infoRow("Symlink", "→ " + t, mono: true) }
                infoRow("Where", entry.path, mono: true)
            }.padding(16)
            Divider().overlay(Flat.hairline)
            HStack(spacing: 10) {
                Button("Copy Path") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.path, forType: .string)
                }
                if isLocal {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
                }
                Spacer()
                Button("Done") { close() }.keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(width: 400)
        .background(Theme.sidebarBackground)
    }

    private func infoRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).frame(width: 92, alignment: .trailing)
            Text(value).font(.system(size: 11.5, design: mono ? .monospaced : .default)).foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

func friendlyKind(_ e: FileEntry) -> String {
    if e.isDir { return "Folder" }
    let ext = (e.name as NSString).pathExtension.lowercased()
    if ext.isEmpty { return "Document" }
    let known: [String: String] = [
        "json": "JSON document", "geojson": "GeoJSON", "csv": "CSV spreadsheet", "tsv": "TSV spreadsheet",
        "md": "Markdown", "markdown": "Markdown", "txt": "Plain text", "log": "Log file",
        "yaml": "YAML", "yml": "YAML", "toml": "TOML", "xml": "XML", "html": "HTML", "pdf": "PDF document",
        "png": "PNG image", "jpg": "JPEG image", "jpeg": "JPEG image", "gif": "GIF image", "svg": "SVG image",
        "webp": "WebP image", "heic": "HEIC image", "mp4": "MP4 video", "mov": "QuickTime video",
        "mp3": "MP3 audio", "wav": "WAV audio", "zip": "ZIP archive", "tar": "TAR archive", "gz": "Gzip archive",
        "py": "Python source", "js": "JavaScript", "ts": "TypeScript", "go": "Go source", "rs": "Rust source",
        "swift": "Swift source", "c": "C source", "cpp": "C++ source", "sh": "Shell script",
        "pt": "PyTorch checkpoint", "ckpt": "Checkpoint", "npy": "NumPy array", "npz": "NumPy archive", "parquet": "Parquet",
    ]
    return known[ext] ?? "\(ext.uppercased()) file"
}
