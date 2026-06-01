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
private struct HomeResp: Codable { let home: String; let roots: [String]; let sep: String }

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
    @Published var selection: String? = nil
    @Published var content: FileContent = .empty
    @Published var sep: String = "/"
    @Published var zoom: CGFloat = 1.0   // preview zoom (⌘+/−/0), independent of the global UI scale

    // editor
    @Published var editing = false
    @Published var dirty = false
    var draft = ""
    var originalText = ""

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

    // MARK: preview zoom (independent of the interface scale)
    func zoomIn()    { zoom = min(4.0, zoom * 1.15) }
    func zoomOut()   { zoom = max(0.4, zoom / 1.15) }
    func zoomReset() { zoom = 1.0 }

    // MARK: editor
    func editorChanged(_ text: String) {
        draft = text
        let d = text != originalText
        if d != dirty { dirty = d }
    }
    func toggleEditing() { editing.toggle() }
    /// Write the current draft (kept live by the editor's immediate change events).
    func save() {
        guard case let .text(_, _, path) = content else { return }
        let text = draft
        Task { if await postWrite(path, Data(text.utf8)) { originalText = text; dirty = false } }
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
                if selection == node.entry.path { selection = nil; content = .empty }
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

    func loadChildren(_ node: FileNode) {
        guard node.children == nil, !node.loading else { return }
        node.loading = true
        Task {
            let kids = await list(node.entry.path)
            node.children = kids ?? []
            node.loading = false
        }
    }

    // MARK: content

    func open(_ node: FileNode) {
        let e = node.entry
        selection = e.path
        guard !e.isDir else { return }
        let kind = kindFor(e.name, size: e.size)
        if kind == .media {
            if let u = readURL(e.path) { content = .media(u) } else { content = .error("bad path") }
            return
        }
        content = .loading(e.path)
        Task { await fetchContent(e, kind: kind) }
    }

    private func fetchContent(_ e: FileEntry, kind: FileKind) async {
        guard let url = readURL(e.path) else { content = .error("bad path"); return }
        do {
            let (data, resp) = try await fsSession.data(from: url)
            if selection != e.path { return }   // user moved on
            if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                content = .error("HTTP \(http.statusCode)"); return
            }
            switch kind {
            case .image:
                content = NSImage(data: data).map { .image($0) } ?? .binary(e)
            case .pdf:
                content = .pdf(data)
            case .text:
                if let s = String(data: data, encoding: .utf8) {
                    editing = false; dirty = false; draft = s; originalText = s
                    content = .text(s, name: e.name, path: e.path)
                } else { content = .binary(e) }
            default:
                content = .binary(e)
            }
        } catch {
            if selection == e.path { content = .error(error.localizedDescription) }
        }
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

    func closeTab(_ id: UUID) {
        tabs.removeAll { $0.id == id }
        if activeID == id { activeID = tabs.last?.id }
    }
}
