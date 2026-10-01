import PDFKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

// MARK: /fs API (internal/fsvc). Paths are absolute and platform-native; only
// list/stat resolve "~", $VARS and relative paths.

struct FSEntry: Decodable, Identifiable, Hashable {
    let name: String
    let path: String
    let isDir: Bool
    let size: Int64?
    let mtime: Int64?
    let symlink: Bool?
    var id: String { path.isEmpty ? name : path }
}

struct FSHome: Decodable { let home: String; let roots: [String]; let sep: String }
struct FSList: Decodable { let path: String?; let entries: [FSEntry]? }
struct FSStat: Decodable { let path: String; let name: String?; let isDir: Bool; let exists: Bool }
struct FSFind: Decodable { let root: String?; let files: [FSEntry]; let truncated: Bool? }
struct FSGrepMatch: Decodable, Hashable, Identifiable {
    let path: String; let line: Int; let text: String
    var id: String { "\(path):\(line)" }
}
struct FSGrep: Decodable { let matches: [FSGrepMatch]; let truncated: Bool? }
struct GitSummary: Decodable {
    struct File: Decodable { let path: String; let staged: String?; let unstaged: String?; let untracked: Bool? }
    let branch: String?; let files: [File]?; let root: String?
}

enum FilesAPI {
    static func home(_ m: Machine) async throws -> FSHome { try await BrokerHTTP.get(m.httpBase, "fs/home", as: FSHome.self) }
    static func list(_ m: Machine, _ path: String) async throws -> FSList {
        try await BrokerHTTP.get(m.httpBase, "fs/list", query: [.init(name: "path", value: path)], as: FSList.self)
    }
    static func stat(_ m: Machine, _ path: String, base: String?) async throws -> FSStat {
        var q: [URLQueryItem] = [.init(name: "path", value: path)]
        if let base { q.append(.init(name: "base", value: base)) }
        return try await BrokerHTTP.get(m.httpBase, "fs/stat", query: q, as: FSStat.self)
    }
    static func readURL(_ m: Machine, _ path: String) -> URL { BrokerHTTP.url(m.httpBase, "fs/read", [.init(name: "path", value: path)]) }
    static func read(_ m: Machine, _ path: String) async throws -> Data {
        let (data, resp) = try await BrokerHTTP.session.data(from: readURL(m, path))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw BrokerError.http(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return data
    }
    static func write(_ m: Machine, _ path: String, _ data: Data) async throws {
        try await BrokerHTTP.post(m.httpBase, "fs/write", query: [.init(name: "path", value: path)], body: data, timeout: 600)
    }
    static func mkdir(_ m: Machine, _ path: String) async throws { try await BrokerHTTP.post(m.httpBase, "fs/mkdir", query: [.init(name: "path", value: path)]) }
    static func rename(_ m: Machine, _ path: String, to: String) async throws {
        try await BrokerHTTP.post(m.httpBase, "fs/rename", query: [.init(name: "path", value: path), .init(name: "to", value: to)])
    }
    static func delete(_ m: Machine, _ path: String) async throws { try await BrokerHTTP.post(m.httpBase, "fs/delete", query: [.init(name: "path", value: path)]) }
    static func find(_ m: Machine, root: String) async throws -> FSFind {
        try await BrokerHTTP.get(m.httpBase, "fs/find", query: [.init(name: "path", value: root), .init(name: "limit", value: "20000")], as: FSFind.self)
    }
    static func grep(_ m: Machine, root: String, query: String) async throws -> FSGrep {
        try await BrokerHTTP.get(m.httpBase, "fs/grep", query: [.init(name: "path", value: root), .init(name: "query", value: query)], as: FSGrep.self)
    }
    static func git(_ m: Machine, dir: String) async -> GitSummary? {
        try? await BrokerHTTP.get(m.httpBase, "git/summary", query: [.init(name: "dir", value: dir)], as: GitSummary.self)
    }
}

enum PathMath {
    static func join(_ dir: String, _ name: String, sep: String) -> String {
        dir.hasSuffix(sep) ? dir + name : dir + sep + name
    }
    /// Parent of an absolute path; "" (the roots) above a top-level path.
    static func parent(_ path: String, sep: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix(sep) { p.removeLast() }
        guard let i = p.range(of: sep, options: .backwards) else { return "" }
        let head = String(p[..<i.lowerBound])
        if head.isEmpty { return p == sep ? "" : sep }            // "/a" → "/"
        if head.hasSuffix(":") { return p == head + sep ? "" : head + sep }   // "C:\a" → "C:\"
        return head
    }
}

enum FileKind {
    case text, markdown, image, pdf, other
    static let imageExt: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "webp", "heic", "tiff", "svg"]
    static let binaryExt: Set<String> = ["zip", "tar", "gz", "tgz", "xz", "7z", "rar", "mp4", "mov", "m4v", "mp3", "wav",
                                         "m4a", "so", "bin", "o", "a", "dylib", "exe", "dll", "jar", "class", "pyc",
                                         "pt", "pth", "ckpt", "safetensors", "npy", "npz", "parquet", "xlsx", "docx",
                                         "pptx", "key", "numbers", "pages"]
    static let textLimit: Int64 = 5_000_000

    static func of(_ name: String, size: Int64?) -> FileKind {
        let ext = (name as NSString).pathExtension.lowercased()
        if imageExt.contains(ext) && ext != "svg" { return .image }
        if ext == "pdf" { return .pdf }
        if binaryExt.contains(ext) || (size ?? 0) > textLimit { return .other }
        if ext == "md" || ext == "markdown" { return .markdown }
        return .text
    }
}

// MARK: Model

@MainActor
final class FilesModel: ObservableObject {
    let machine: Machine
    @Published var path: String = ""
    @Published var entries: [FSEntry] = []
    @Published var sep = "/"
    @Published var home = ""
    @Published var error: String?
    @Published var loading = false
    @Published var git: [String: String] = [:]   // absolute path → letter ("M", "U", "•" for dirs)
    @Published var branch: String?
    @Published var transfer: String?

    init(machine: Machine) { self.machine = machine }

    func start(at initial: String? = nil) async {
        if let h = try? await FilesAPI.home(machine) { sep = h.sep; home = h.home }
        if let initial, !initial.isEmpty, let st = try? await FilesAPI.stat(machine, initial, base: home), st.exists {
            await go(st.isDir ? st.path : PathMath.parent(st.path, sep: sep))
        } else {
            await go(home)
        }
    }

    func go(_ p: String) async {
        loading = true
        defer { loading = false }
        do {
            let r = try await FilesAPI.list(machine, p)
            path = r.path ?? p
            entries = (r.entries ?? []).sorted { a, b in
                a.isDir != b.isDir ? a.isDir : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            error = nil
            await loadGit()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func up() async { await go(PathMath.parent(path, sep: sep)) }
    func refresh() async { await go(path) }

    private func loadGit() async {
        git = [:]; branch = nil
        guard !path.isEmpty, let g = await FilesAPI.git(machine, dir: path), let root = g.root else { return }
        branch = g.branch
        var marks: [String: String] = [:]
        for f in g.files ?? [] {
            let abs = PathMath.join(root, f.path, sep: sep)
            let letter: String = {
                if f.untracked == true { return "U" }
                if let s = f.staged, s != "." { return s }
                if let u = f.unstaged, u != "." { return u }
                return "M"
            }()
            marks[abs] = letter
            var dir = PathMath.parent(abs, sep: sep)
            while dir.count >= root.count, !dir.isEmpty, marks[dir] == nil {
                marks[dir] = "•"
                dir = PathMath.parent(dir, sep: sep)
            }
        }
        git = marks
    }

    func mkdir(_ name: String) async {
        await act { try await FilesAPI.mkdir(self.machine, PathMath.join(self.path, name, sep: self.sep)) }
    }
    func rename(_ e: FSEntry, to name: String) async {
        await act { try await FilesAPI.rename(self.machine, e.path, to: PathMath.join(PathMath.parent(e.path, sep: self.sep), name, sep: self.sep)) }
    }
    func delete(_ e: FSEntry) async { await act { try await FilesAPI.delete(self.machine, e.path) } }

    func upload(_ urls: [URL]) async {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            transfer = "Uploading \(url.lastPathComponent)…"
            do {
                let data = try Data(contentsOf: url)
                try await FilesAPI.write(machine, PathMath.join(path, url.lastPathComponent, sep: sep), data)
            } catch { self.error = "Upload failed: \(error.localizedDescription)" }
        }
        transfer = nil
        await refresh()
    }

    /// Downloads to a temporary file named like the original (for sharing/QuickLook).
    func download(_ e: FSEntry) async -> URL? {
        transfer = "Downloading \(e.name)…"
        defer { transfer = nil }
        do {
            let data = try await FilesAPI.read(machine, e.path)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(e.name)
            try data.write(to: url)
            return url
        } catch {
            self.error = "Download failed: \(error.localizedDescription)"
            return nil
        }
    }

    private func act(_ body: @escaping () async throws -> Void) async {
        do { try await body(); await refresh() } catch { self.error = error.localizedDescription }
    }
}

// MARK: Views

struct FilesTab: View {
    @EnvironmentObject var fleet: FleetStore
    @EnvironmentObject var router: AppRouter
    @State private var machineID: String?

    var body: some View {
        Group {
            if let m = fleet.machines.first(where: { $0.id == machineID }) ?? fleet.machines.first {
                let target = router.filesTarget?.machineID == m.id ? router.filesTarget : nil
                FilesBrowser(machine: m, initialPath: target?.path).id(m.id + (target.map { $0.id.uuidString } ?? ""))
            } else {
                ContentUnavailableView("No machines", systemImage: "externaldrive", description: Text("Waiting for machines…"))
            }
        }
        .onChange(of: router.filesTarget) { _, t in if let t { machineID = t.machineID } }
        .onAppear { if let t = router.filesTarget { machineID = t.machineID } }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(fleet.machines) { m in Button(m.name) { machineID = m.id; router.filesTarget = nil } }
                } label: {
                    Label(fleet.machines.first(where: { $0.id == machineID })?.name ?? fleet.machines.first?.name ?? "Machine",
                          systemImage: "server.rack")
                }
            }
        }
    }
}

struct FilesBrowser: View {
    let machine: Machine
    let initialPath: String?
    @StateObject private var model: FilesModel
    @State private var filter = ""
    @State private var searchMode = SearchMode.name
    @State private var deepResults: [FSEntry] = []
    @State private var grepResults: [FSGrepMatch] = []
    @State private var searching = false
    @State private var importing = false
    @State private var newFolder = false
    @State private var newName = ""
    @State private var renaming: FSEntry?
    @State private var deleting: FSEntry?
    @State private var shareItem: ShareItem?

    enum SearchMode: String, CaseIterable { case name = "This folder", deep = "All files", content = "Contents" }

    init(machine: Machine, initialPath: String?) {
        self.machine = machine
        self.initialPath = initialPath
        _model = StateObject(wrappedValue: FilesModel(machine: machine))
    }

    var body: some View {
        List {
            Section {
                Button { Task { await model.up() } } label: {
                    Label(model.path.isEmpty ? "Computer" : model.path, systemImage: "arrow.up.left")
                        .font(.caption.monospaced()).lineLimit(2).truncationMode(.head)
                }
                .disabled(model.path.isEmpty)
                if let b = model.branch { Label(b, systemImage: "arrow.triangle.branch").font(.caption) }
                if let t = model.transfer { HStack { ProgressView(); Text(t).font(.caption) } }
                if let e = model.error { Text(e).font(.caption).foregroundStyle(.red) }
            }
            if !filter.isEmpty && searchMode != .name {
                searchResults
            } else {
                Section {
                    ForEach(visible) { e in row(e) }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(machine.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter, prompt: "Search")
        .searchScopes($searchMode) { ForEach(SearchMode.allCases, id: \.self) { Text($0.rawValue) } }
        .onSubmit(of: .search) { Task { await runSearch() } }
        .onChange(of: searchMode) { _, _ in Task { await runSearch() } }
        .refreshable { await model.refresh() }
        .task { await model.start(at: initialPath) }
        .navigationDestination(for: FilePreviewRoute.self) { FilePreview(model: model, entry: $0.entry, line: $0.line) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { importing = true } label: { Label("Upload", systemImage: "square.and.arrow.up") }
                    Button { newName = ""; newFolder = true } label: { Label("New folder", systemImage: "folder.badge.plus") }
                    Button { Task { await model.go(model.home) } } label: { Label("Home", systemImage: "house") }
                    Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                } label: { Image(systemName: "ellipsis.circle") }
                .disabled(model.path.isEmpty)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { Task { await model.upload(urls) } }
        }
        .alert("New folder", isPresented: $newFolder) {
            TextField("name", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Create") { Task { await model.mkdir(newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("name", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Rename") { if let e = renaming { Task { await model.rename(e, to: newName) } } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(deleting.map { "Delete \($0.name)?" } ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) { if let e = deleting { Task { await model.delete(e) } } }
        } message: { Text(deleting?.isDir == true ? "This deletes the folder and everything in it." : "This can't be undone.") }
        .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
    }

    private var visible: [FSEntry] {
        guard !filter.isEmpty, searchMode == .name else { return model.entries }
        return model.entries.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    @ViewBuilder private var searchResults: some View {
        if searching { HStack { ProgressView(); Text("Searching…") } }
        if searchMode == .deep {
            Section("\(deepResults.count) files") {
                ForEach(deepResults) { e in
                    NavigationLink(value: FilePreviewRoute(entry: e)) {
                        VStack(alignment: .leading) {
                            Text(e.name)
                            Text(e.path).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                    }
                }
            }
        } else {
            Section("\(grepResults.count) matches") {
                ForEach(grepResults) { m in
                    NavigationLink(value: FilePreviewRoute(entry: FSEntry(name: (m.path as NSString).lastPathComponent, path: m.path,
                                                                            isDir: false, size: nil, mtime: nil, symlink: nil), line: m.line)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\((m.path as NSString).lastPathComponent):\(m.line)").font(.caption.weight(.medium))
                            Text(m.text).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private func runSearch() async {
        guard !filter.isEmpty, !model.path.isEmpty, searchMode != .name else { return }
        searching = true
        defer { searching = false }
        do {
            if searchMode == .deep {
                let r = try await FilesAPI.find(machine, root: model.path)
                deepResults = r.files.filter { $0.name.localizedCaseInsensitiveContains(filter) }.prefix(500).map { $0 }
            } else {
                grepResults = try await FilesAPI.grep(machine, root: model.path, query: filter).matches
            }
        } catch { model.error = error.localizedDescription }
    }

    @ViewBuilder private func row(_ e: FSEntry) -> some View {
        let label = HStack {
            Image(systemName: e.isDir ? "folder.fill" : icon(e.name)).foregroundStyle(e.isDir ? .blue : .secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.name).foregroundStyle(gitColor(e) ?? .primary).lineLimit(1)
                if !e.isDir, let s = e.size {
                    Text(ByteCountFormatter.string(fromByteCount: s, countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let g = model.git[e.path] { Text(g).font(.caption.monospaced().bold()).foregroundStyle(gitColor(e) ?? .secondary) }
        }
        Group {
            if e.isDir {
                Button { Task { await model.go(e.path) } } label: { label }.foregroundStyle(.primary)
            } else {
                NavigationLink(value: FilePreviewRoute(entry: e)) { label }
            }
        }
        .contextMenu {
            if !e.isDir {
                Button { Task { if let u = await model.download(e) { shareItem = ShareItem(url: u) } } } label: {
                    Label("Share / Save", systemImage: "square.and.arrow.up")
                }
            }
            Button { UIPasteboard.general.string = e.path } label: { Label("Copy path", systemImage: "doc.on.doc") }
            Button { newName = e.name; renaming = e } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) { deleting = e } label: { Label("Delete", systemImage: "trash") }
        }
        .swipeActions {
            Button(role: .destructive) { deleting = e } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func gitColor(_ e: FSEntry) -> Color? {
        switch model.git[e.path] {
        case "U", "A", "?": return .green
        case "D": return .red
        case nil: return nil
        default: return .orange
        }
    }

    private func icon(_ name: String) -> String {
        switch FileKind.of(name, size: nil) {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .markdown: return "doc.text"
        case .text: return "doc.plaintext"
        case .other: return "doc"
        }
    }
}

struct FilePreviewRoute: Hashable {
    let entry: FSEntry
    var line: Int? = nil
}

struct ShareItem: Identifiable { let url: URL; var id: URL { url } }

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_: UIActivityViewController, context: Context) {}
}

// MARK: Preview

struct FilePreview: View {
    @ObservedObject var model: FilesModel
    let entry: FSEntry
    let line: Int?
    @State private var data: Data?
    @State private var text = ""
    @State private var saved = ""
    @State private var editing = false
    @State private var error: String?
    @State private var fontSize: CGFloat = 12
    @State private var localURL: URL?
    @State private var shareItem: ShareItem?
    @State private var renderMarkdown = true

    private var kind: FileKind { FileKind.of(entry.name, size: entry.size) }

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("Couldn't open", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if data == nil && localURL == nil {
                ProgressView()
            } else {
                content
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task { await load() }
        .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .image:
            if let data, let img = UIImage(data: data) { ZoomableImage(image: img) } else { quickLook }
        case .pdf:
            if let data { PDFKitView(data: data) }
        case .other:
            quickLook
        case .markdown where renderMarkdown && !editing:
            ScrollView {
                Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                    .font(.body).textSelection(.enabled).padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .text, .markdown:
            if editing {
                TextEditor(text: $text).font(.system(size: fontSize, design: .monospaced))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            } else {
                CodeText(text: text, fontSize: fontSize, line: line)
            }
        }
    }

    @ViewBuilder private var quickLook: some View {
        if let localURL { QuickLookView(url: localURL) } else { ProgressView() }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if kind == .text || kind == .markdown {
                if editing {
                    Button("Save") { Task { await save() } }.disabled(text == saved)
                } else {
                    if kind == .markdown {
                        Button { renderMarkdown.toggle() } label: { Image(systemName: renderMarkdown ? "chevron.left.forwardslash.chevron.right" : "doc.richtext") }
                    }
                    Menu {
                        Button("Edit") { editing = true }
                        Button("Larger text") { fontSize = min(fontSize + 1, 40) }
                        Button("Smaller text") { fontSize = max(fontSize - 1, 7) }
                    } label: { Image(systemName: "textformat.size") }
                }
            }
            Button {
                Task {
                    if localURL == nil { localURL = await model.download(entry) }
                    if let u = localURL { shareItem = ShareItem(url: u) }
                }
            } label: { Image(systemName: "square.and.arrow.up") }
        }
    }

    private func load() async {
        do {
            if kind == .other {
                localURL = await model.download(entry)
                if localURL == nil { error = model.error ?? "Download failed" }
                return
            }
            let d = try await FilesAPI.read(model.machine, entry.path)
            data = d
            if kind == .text || kind == .markdown {
                text = String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
                saved = text
            }
        } catch { self.error = error.localizedDescription }
    }

    private func save() async {
        do {
            try await FilesAPI.write(model.machine, entry.path, Data(text.utf8))
            saved = text
            editing = false
        } catch { self.error = "Save failed: \(error.localizedDescription)" }
    }
}

/// Monospaced, selectable, with line numbers; scrolls to `line` if given.
struct CodeText: View {
    let text: String
    let fontSize: CGFloat
    let line: Int?

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.prefix(50_000).enumerated()), id: \.offset) { i, l in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(i + 1)").foregroundStyle(.tertiary).frame(minWidth: 36, alignment: .trailing)
                            Text(l.isEmpty ? " " : l)
                        }
                        .font(.system(size: fontSize, design: .monospaced))
                        .background(i + 1 == line ? Color.yellow.opacity(0.2) : .clear)
                        .id(i + 1)
                    }
                }
                .textSelection(.enabled)
                .padding(8)
            }
            .onAppear { if let line { proxy.scrollTo(line, anchor: .center) } }
        }
    }
}

struct ZoomableImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Image(uiImage: image).resizable().scaledToFit()
                .frame(width: UIScreen.main.bounds.width * scale * pinch)
        }
        .gesture(MagnificationGesture().updating($pinch) { v, s, _ in s = v }.onEnded { scale = min(max(scale * $0, 0.25), 8) })
        .onTapGesture(count: 2) { scale = scale > 1 ? 1 : 2.5 }
    }
}

struct PDFKitView: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.document = PDFDocument(data: data)
        return v
    }
    func updateUIView(_: PDFView, context: Context) {}
}

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        c.dataSource = context.coordinator
        return c
    }
    func updateUIViewController(_: QLPreviewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in _: QLPreviewController) -> Int { 1 }
        func previewController(_: QLPreviewController, previewItemAt _: Int) -> QLPreviewItem { url as NSURL }
    }
}
