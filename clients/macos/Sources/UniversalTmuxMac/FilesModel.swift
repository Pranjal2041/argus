import AppKit
import Foundation

/// A URLSession that never serves cached responses — so re-opening a file after a
/// save (or an external change) always reflects what's on disk, not a stale, still
/// heuristically-"fresh" cache entry.
private let fsSession: URLSession = {
    let cfg = URLSessionConfiguration.default
    cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    cfg.urlCache = nil
    return URLSession(configuration: cfg)
}()

// MARK: - wire types (mirror the broker's /fs JSON)

struct FileEntry: Codable, Hashable {
    let name: String
    let path: String          // absolute, platform-native (we never join paths ourselves)
    let isDir: Bool
    let size: Int64
    let mtime: Int64
    let mode: String
    var symlink: Bool? = nil   // omitempty on the wire: must be decode-optional, else
    var target: String? = nil  // a missing key throws keyNotFound and the whole list fails
}

private struct ListResp: Codable { let path: String; let entries: [FileEntry] }
private struct FindResp: Codable { let root: String; let files: [FileEntry]; let truncated: Bool }
private struct HomeResp: Codable { let home: String; let roots: [String]; let sep: String }
private struct StatResp: Codable { let path: String; let name: String; let isDir: Bool; let exists: Bool; let size: Int64 }

// MARK: - tree node (reference type for lazy expansion)

final class FileNode: ObservableObject, Identifiable {
    let entry: FileEntry
    var id: String { entry.path }
    @Published var children: [FileNode]? = nil   // nil = not loaded yet
    @Published var expanded = false
    @Published var loading = false
    init(_ e: FileEntry) { entry = e }
}

enum FileKind { case text, image, pdf, media, binary }

enum FileContent {
    case empty
    case loading(String)
    case text(String, name: String, path: String)
    case image(NSImage)
    case pdf(Data)
    case media(URL)          // streamed by AVPlayer (Range), never fully downloaded
    case binary(FileEntry)
    case error(String)
}

/// How a markdown document is shown: just the editor, editor+preview side by side,
/// or just the rendered preview.
enum PreviewMode: String { case editor, split, preview }

/// One open file in a browser tab — its content + per-file edit/zoom/preview state.
/// A FileTab keeps a list of these (VS Code-style per-file tabs) and shows the active
/// one in the content pane.
@MainActor
final class OpenDoc: ObservableObject, Identifiable {
    let id = UUID()
    let path: String
    let name: String
    @Published var content: FileContent
    @Published var dirty = false
    @Published var draft = ""   // @Published so a live markdown preview re-renders as you type
    var originalText = ""
    @Published var zoom: CGFloat = 1.0
    @Published var pendingLine: Int? = nil
    @Published var previewMode: PreviewMode = .editor

    init(path: String, name: String, content: FileContent) {
        self.path = path; self.name = name; self.content = content
    }

    var isMarkdown: Bool {
        ["md", "markdown", "mdx", "mdown", "mkd"].contains((name as NSString).pathExtension.lowercased())
    }

    func editorChanged(_ text: String) {
        draft = text
        let d = text != originalText
        if d != dirty { dirty = d }
    }
    /// Adopt freshly-loaded text as the clean baseline.
    func loadedText(_ s: String) { draft = s; originalText = s; dirty = false; content = .text(s, name: name, path: path) }
    func markSaved() { originalText = draft; dirty = false }

    func zoomIn()    { zoom = min(4.0, zoom * 1.15) }
    func zoomOut()   { zoom = max(0.4, zoom / 1.15) }
    func zoomReset() { zoom = 1.0 }
}

/// A pending "new" operation (drives the new-folder/new-file dialog).
struct NewItem: Identifiable { let id = UUID(); let parent: String; let isDir: Bool }

/// Progress of an in-flight upload (drives the upload banner).
struct UploadState { let name: String; var progress: Double }

/// URLSession task delegate that reports upload byte progress.
private final class UploadProgress: NSObject, URLSessionTaskDelegate {
    let cb: (Double) -> Void
    init(_ cb: @escaping (Double) -> Void) { self.cb = cb }
    func urlSession(_ s: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let p = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        Task { @MainActor in cb(p) }
    }
}

/// URLSession download delegate that reports download byte progress.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate {
    let cb: (Double) -> Void
    init(_ cb: @escaping (Double) -> Void) { self.cb = cb }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        Task { @MainActor in cb(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

// MARK: - one browsing tab (a host + a current root directory)

@MainActor
final class FileTab: ObservableObject, Identifiable {
    let id = UUID()
    let machineID: String
    let machineName: String
    let httpBase: String
    let isLocal: Bool

    @Published var title: String
    @Published var rootPath: String = ""
    @Published var roots: [FileNode] = []
    /// Bumped whenever the tree's *shape* changes (expand/collapse/children load) so the
    /// flattened visible-row list recomputes — expansion lives on each FileNode, which the
    /// flattener reads but the view can't individually observe.
    @Published private(set) var treeRevision = 0
    private func bumpTree() { treeRevision &+= 1 }
    @Published var selection: String? = nil   // the file highlighted in the tree
    @Published var sep: String = "/"

    // Open files (per-file tabs). The active one shows in the content pane.
    @Published var openDocs: [OpenDoc] = []
    @Published var activeDocID: UUID? = nil
    var activeDoc: OpenDoc? { openDocs.first { $0.id == activeDocID } }
    @Published var pendingClose: OpenDoc? = nil   // a dirty tab awaiting a save/discard choice

    // ⌘P quick-open: a fuzzy file finder over the current root.
    @Published var showQuickOpen = false
    @Published var quickOpenFiles: [FileEntry] = []
    @Published var quickOpenLoading = false
    private var quickOpenRoot: String? = nil       // root the cached file list was built for

    // pending dialog ops (driven from the tree's context menu, shown by the view)
    @Published var renaming: FileNode? = nil
    @Published var creating: NewItem? = nil
    @Published var deleting: FileNode? = nil
    @Published var uploading: UploadState? = nil
    @Published var downloading: UploadState? = nil

    private let textCap: Int64 = 5_000_000   // above this, don't auto-load as text

    init(machine: Machine) {
        machineID = machine.id
        machineName = machine.name
        httpBase = machine.httpBase
        isLocal = machine.isLocal
        title = machine.name
    }

    // MARK: navigation

    func start(at startPath: String? = nil) {
        Task {
            var initial = startPath
            if let url = URL(string: httpBase + "/fs/home"),
               let (d, _) = try? await fsSession.data(from: url),
               let h = try? JSONDecoder().decode(HomeResp.self, from: d) {
                sep = h.sep
                if initial == nil || initial!.isEmpty { initial = h.home }
            }
            await setRoot(initial ?? "")
        }
    }

    func setRoot(_ path: String) async {
        let kids = await list(path)
        rootPath = path
        roots = kids ?? []
        title = displayName(path)
    }

    func goUp() { Task { await setRoot(parentPath(rootPath)) } }
    func goHome() { start() }

    // MARK: active-doc convenience (toolbar + ⌘-shortcuts act on the active file)
    func zoomIn()    { activeDoc?.zoomIn() }
    func zoomOut()   { activeDoc?.zoomOut() }
    func zoomReset() { activeDoc?.zoomReset() }

    /// Write the active doc's live draft (kept current by the editor's change events).
    func save() { if let doc = activeDoc { save(doc) } }
    func save(_ doc: OpenDoc) {
        guard case .text = doc.content else { return }
        let text = doc.draft, path = doc.path
        Task { if await postWrite(path, Data(text.utf8)) { doc.markSaved() } }
    }

    /// Focus an already-open doc (or no-op). Keeps the tree highlight in sync.
    func activate(_ doc: OpenDoc) { activeDocID = doc.id; selection = doc.path }

    /// Close request from the tab's × — confirms first if the doc has unsaved edits.
    func requestClose(_ doc: OpenDoc) {
        if doc.dirty { pendingClose = doc } else { closeDoc(doc.id) }
    }

    func closeDoc(_ id: UUID) {
        guard let idx = openDocs.firstIndex(where: { $0.id == id }) else { return }
        openDocs.remove(at: idx)
        if activeDocID == id {
            let next = openDocs.indices.contains(idx) ? openDocs[idx] : openDocs.last
            activeDocID = next?.id
            selection = next?.path
        }
    }

    // MARK: quick-open (⌘P)
    func openQuickOpen() {
        showQuickOpen = true
        guard !rootPath.isEmpty else { return }
        if quickOpenRoot == rootPath, !quickOpenFiles.isEmpty { return }   // cached for this root
        quickOpenLoading = true
        let root = rootPath
        Task {
            let files = await fetchFind(root)
            guard rootPath == root else { return }   // user navigated away
            quickOpenFiles = files
            quickOpenRoot = root
            quickOpenLoading = false
        }
    }
    func closeQuickOpen() { showQuickOpen = false }

    private func fetchFind(_ root: String) async -> [FileEntry] {
        guard var c = URLComponents(string: httpBase + "/fs/find") else { return [] }
        c.queryItems = [.init(name: "path", value: root), .init(name: "limit", value: "20000")]
        guard let url = c.url,
              let (data, _) = try? await fsSession.data(from: url),
              let res = try? JSONDecoder().decode(FindResp.self, from: data) else { return [] }
        return res.files
    }

    // MARK: file operations (context-menu ops)
    func mkdir(in parent: String, name: String) {
        Task { if await post("/fs/mkdir", ["path": joined(parent, name)]) { await refresh(parent) } }
    }
    func createFile(in parent: String, name: String) {
        Task { if await postWrite(joined(parent, name), Data()) { await refresh(parent) } }
    }
    func rename(_ node: FileNode, to newName: String) {
        let parent = parentPath(node.entry.path)
        Task { if await post("/fs/rename", ["path": node.entry.path, "to": joined(parent, newName)]) { await refresh(parent) } }
    }
    func delete(_ node: FileNode) {
        let parent = parentPath(node.entry.path)
        Task {
            if await post("/fs/delete", ["path": node.entry.path]) {
                if let d = openDocs.first(where: { $0.path == node.entry.path }) { closeDoc(d.id) }
                if selection == node.entry.path { selection = nil }
                await refresh(parent)
            }
        }
    }
    func refreshDir(_ path: String) { Task { await refresh(path) } }

    /// Download `entry` to a local destination, with progress.
    func download(_ entry: FileEntry, to dest: URL) {
        guard let url = readURL(entry.path) else { return }
        Task {
            downloading = UploadState(name: entry.name, progress: 0)
            let delegate = DownloadProgress { [weak self] p in self?.downloading?.progress = p }
            if let (tmp, resp) = try? await URLSession.shared.download(from: url, delegate: delegate),
               ((resp as? HTTPURLResponse)?.statusCode ?? 200) < 400 {
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.moveItem(at: tmp, to: dest)
            }
            downloading = nil
        }
    }

    func upload(into dir: String, name: String, data: Data) {
        Task {
            uploading = UploadState(name: name, progress: 0)
            let ok = await uploadWrite(joined(dir, name), name: name, data: data)
            uploading = nil
            if ok { await refresh(dir) }
        }
    }
    private func uploadWrite(_ path: String, name: String, data: Data) async -> Bool {
        guard var c = URLComponents(string: httpBase + "/fs/write") else { return false }
        c.queryItems = [.init(name: "path", value: path)]
        guard let url = c.url else { return false }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        let delegate = UploadProgress { [weak self] p in self?.uploading?.progress = p }
        guard let (_, resp) = try? await URLSession.shared.upload(for: req, from: data, delegate: delegate) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: op helpers
    @discardableResult
    private func post(_ ep: String, _ params: [String: String]) async -> Bool {
        guard var c = URLComponents(string: httpBase + ep) else { return false }
        c.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = c.url else { return false }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
    private func postWrite(_ path: String, _ body: Data) async -> Bool {
        guard var c = URLComponents(string: httpBase + "/fs/write") else { return false }
        c.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = c.url else { return false }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.httpBody = body
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
    private func refresh(_ dir: String) async {
        if dir.isEmpty || dir == rootPath {
            roots = (await list(rootPath)) ?? []
        } else if let node = findNode(dir, roots) {
            node.children = (await list(dir)) ?? []
            node.expanded = true
        } else {
            roots = (await list(rootPath)) ?? []
        }
        bumpTree()
    }
    private func findNode(_ path: String, _ nodes: [FileNode]) -> FileNode? {
        for n in nodes {
            if n.entry.path == path { return n }
            if let kids = n.children, let f = findNode(path, kids) { return f }
        }
        return nil
    }
    private func joined(_ parent: String, _ name: String) -> String {
        parent.hasSuffix(sep) ? parent + name : parent + sep + name
    }
    func parentOf(_ path: String) -> String { parentPath(path) }
    func setRootPath(_ path: String) { Task { await setRoot(path) } }

    /// Toggle a directory open/closed (loading children on first open) and select it.
    /// Bumps `treeRevision` so the flattened visible-row list recomputes.
    func toggleExpand(_ node: FileNode) {
        node.expanded.toggle()
        selection = node.entry.path
        if node.expanded { loadChildren(node) }
        bumpTree()
    }

    func loadChildren(_ node: FileNode) {
        guard node.children == nil, !node.loading else { return }
        node.loading = true
        bumpTree()
        Task {
            let kids = await list(node.entry.path)
            node.children = kids ?? []
            node.loading = false
            bumpTree()
        }
    }

    // MARK: content

    func open(_ node: FileNode) {
        let e = node.entry
        selection = e.path
        guard !e.isDir else { return }
        openEntry(e, line: nil)
    }

    /// Open a file as a doc, or focus it if already open; jump to `line` if given.
    func openEntry(_ e: FileEntry, line: Int?) {
        selection = e.path
        if let existing = openDocs.first(where: { $0.path == e.path }) {
            activeDocID = existing.id
            if let line { existing.pendingLine = line }
            return
        }
        let kind = kindFor(e.name, size: e.size)
        let initial: FileContent = (kind == .media)
            ? (readURL(e.path).map { .media($0) } ?? .error("bad path"))
            : .loading(e.path)
        let doc = OpenDoc(path: e.path, name: e.name, content: initial)
        doc.pendingLine = line
        openDocs.append(doc)
        activeDocID = doc.id
        if kind == .media { return }
        Task { await fetchContent(e, into: doc, kind: kind) }
    }

    private func fetchContent(_ e: FileEntry, into doc: OpenDoc, kind: FileKind) async {
        guard let url = readURL(e.path) else { doc.content = .error("bad path"); return }
        do {
            let (data, resp) = try await fsSession.data(from: url)
            guard openDocs.contains(where: { $0.id == doc.id }) else { return }   // tab closed mid-fetch
            if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                doc.content = .error("HTTP \(http.statusCode)"); return
            }
            switch kind {
            case .image:
                doc.content = NSImage(data: data).map { .image($0) } ?? .binary(e)
            case .pdf:
                doc.content = .pdf(data)
            case .text:
                if let s = String(data: data, encoding: .utf8) { doc.loadedText(s) }
                else { doc.content = .binary(e) }
            default:
                doc.content = .binary(e)
            }
        } catch {
            if openDocs.contains(where: { $0.id == doc.id }) { doc.content = .error(error.localizedDescription) }
        }
    }

    /// Open a path a terminal cmd+click resolved (via /fs/stat) on this host:
    /// a directory roots the tree there; a file roots the tree at its parent and
    /// previews it, jumping to `line` if one was clicked. A path that no longer
    /// exists falls back to showing its parent directory.
    func openResolved(_ path: String, isDir: Bool, exists: Bool, name: String, size: Int64, line: Int?) async {
        // Learn the host's separator so parentPath() is correct (Win `\` vs Unix `/`).
        if let url = URL(string: httpBase + "/fs/home"),
           let (d, _) = try? await fsSession.data(from: url),
           let h = try? JSONDecoder().decode(HomeResp.self, from: d) {
            sep = h.sep
        }
        if isDir {
            await setRoot(path)
            selection = path
            return
        }
        await setRoot(parentPath(path))   // show the file's directory context
        guard exists else { return }       // parent shown; the file itself is gone
        let e = FileEntry(name: name, path: path, isDir: false, size: size, mtime: 0, mode: "")
        openEntry(e, line: line)           // opens (or focuses) the file as a doc, jumping to `line`
    }

    // MARK: helpers

    private func list(_ path: String) async -> [FileNode]? {
        guard var c = URLComponents(string: httpBase + "/fs/list") else { return nil }
        c.queryItems = [.init(name: "path", value: path)]
        guard let url = c.url else { return nil }
        do {
            let (data, _) = try await fsSession.data(from: url)
            return try JSONDecoder().decode(ListResp.self, from: data).entries.map { FileNode($0) }
        } catch { return nil }
    }

    func readURL(_ path: String) -> URL? {
        guard var c = URLComponents(string: httpBase + "/fs/read") else { return nil }
        c.queryItems = [.init(name: "path", value: path)]
        return c.url
    }

    private func kindFor(_ name: String, size: Int64) -> FileKind {
        let ext = (name as NSString).pathExtension.lowercased()
        let images: Set<String> = ["png","jpg","jpeg","gif","bmp","tiff","tif","webp","heic","heif","ico","icns"]
        let video: Set<String> = ["mp4","mov","m4v","avi","mkv","webm"]
        let audio: Set<String> = ["mp3","wav","aac","m4a","flac","ogg","oga","aiff","aif"]
        if images.contains(ext) { return .image }
        if video.contains(ext) || audio.contains(ext) { return .media }
        if ext == "pdf" { return .pdf }
        if size > textCap { return .binary }
        return .text   // fetchContent downgrades to .binary if not valid UTF-8
    }

    private func displayName(_ path: String) -> String {
        if path.isEmpty { return machineName }
        let trimmed = path.hasSuffix(sep) && path.count > 1 ? String(path.dropLast()) : path
        if let r = trimmed.range(of: sep, options: .backwards) {
            let tail = String(trimmed[r.upperBound...])
            return tail.isEmpty ? trimmed : tail
        }
        return trimmed
    }

    private func parentPath(_ p: String) -> String {
        var s = p
        while s.count > 1 && s.hasSuffix(sep) { s.removeLast() }   // trim trailing sep (keep lone root)
        guard let r = s.range(of: sep, options: .backwards) else { return "" } // no sep -> roots/drives
        let parent = String(s[..<r.lowerBound])
        if parent.isEmpty { return sep }                  // unix: "/Users" -> "/"
        if !parent.contains(sep) { return parent + sep }  // windows: "C:\Users" -> "C:\"
        return parent
    }
}

// MARK: - the window's model (a set of tabs)

@MainActor
final class FilesModel: ObservableObject {
    @Published var tabs: [FileTab] = []
    @Published var activeID: UUID?

    var active: FileTab? { tabs.first { $0.id == activeID } }

    @discardableResult
    func addTab(_ machine: Machine, startPath: String? = nil) -> FileTab {
        let t = FileTab(machine: machine)
        tabs.append(t)
        activeID = t.id
        t.start(at: startPath)
        return t
    }

    /// Open a path clicked in `machine`'s terminal: resolve+classify it on that host
    /// (relative paths against the session cwd `base`), then root the tree / preview
    /// the file. `line` jumps the editor when a `file:line` was clicked.
    func openTerminalPath(_ machine: Machine, rawPath: String, base: String, line: Int?) {
        let t = FileTab(machine: machine)
        tabs.append(t)
        activeID = t.id
        Task {
            if let s = await Self.stat(machine.httpBase, path: rawPath, base: base) {
                await t.openResolved(s.path, isDir: s.isDir, exists: s.exists, name: s.name, size: s.size, line: line)
            } else {
                t.start()   // old broker without /fs/stat → fall back to home
            }
        }
    }

    private static func stat(_ httpBase: String, path: String, base: String) async -> StatResp? {
        guard var c = URLComponents(string: httpBase + "/fs/stat") else { return nil }
        c.queryItems = [.init(name: "path", value: path), .init(name: "base", value: base)]
        guard let url = c.url,
              let (d, _) = try? await fsSession.data(from: url) else { return nil }
        return try? JSONDecoder().decode(StatResp.self, from: d)
    }

    func closeTab(_ id: UUID) {
        tabs.removeAll { $0.id == id }
        if activeID == id { activeID = tabs.last?.id }
    }
}
