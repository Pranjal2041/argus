import Foundation

// HTTP to the Weekly Progress provider and the on-device cache of its assets.

enum WeeklyProgressAPI {
    struct Reply {
        let ok: Bool
        /// nil when no HTTP response arrived (transport failure).
        let status: Int?
        let error: String?
    }

    private struct ErrorBody: Decodable { let error: String? }

    /// The decoded catalog and its raw bytes (persisted for offline use), or
    /// nil when this broker doesn't serve a Weekly Progress provider.
    static func catalog(_ m: Machine) async -> (WeeklyProgressCatalog, Data)? {
        guard let data = try? await BrokerHTTP.getData(m.httpBase, "weekly-progress/catalog", timeout: 8),
              let catalog = try? WeeklyProgressCatalog.decode(data) else { return nil }
        return (catalog, data)
    }

    static func generate(_ m: Machine, projectID: String, week: String, requestID: String) async -> Reply {
        await command(m, "generate", ["project_id": projectID, "week_start": week, "request_id": requestID])
    }

    static func resume(_ m: Machine, generationID: String, requestID: String) async -> Reply {
        await command(m, "resume", ["generation_id": generationID, "request_id": requestID])
    }

    private static func command(_ m: Machine, _ endpoint: String, _ payload: [String: String]) async -> Reply {
        do {
            let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let (data, response) = try await BrokerHTTP.raw("POST", m.httpBase, "weekly-progress/\(endpoint)", body: body,
                                                            contentType: "application/json", timeout: 20)
            let ok = (200..<300).contains(response.statusCode)
            let error = ok ? nil : (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            return Reply(ok: ok, status: response.statusCode, error: error)
        } catch {
            return Reply(ok: false, status: nil, error: error.localizedDescription)
        }
    }

    static func slide(_ m: Machine, generationID: String, number: Int) async throws -> Data {
        try await BrokerHTTP.getData(m.httpBase, "weekly-progress/asset/\(generationID)/slide/\(number)", timeout: 30)
    }

    static func report(_ m: Machine, generationID: String) async throws -> String {
        let data = try await BrokerHTTP.getData(m.httpBase, "weekly-progress/asset/\(generationID)/report", timeout: 30)
        return String(decoding: data, as: UTF8.self)
    }

    /// Streams the deck to a temporary file, reporting progress (0…1, or -1 if unknown).
    static func downloadDeck(_ m: Machine, generationID: String,
                             progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        var request = URLRequest(url: BrokerHTTP.url(m.httpBase, "weekly-progress/asset/\(generationID)/deck", []))
        request.timeoutInterval = 60
        let observer = DownloadProgressObserver(progress)
        let (file, response) = try await BrokerHTTP.session.download(for: request, delegate: observer)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw BrokerError.http("The PowerPoint could not be downloaded (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        return file
    }

    /// Observes a task's `Progress` (the per-task delegate only sees the task's creation).
    private final class DownloadProgressObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let report: @Sendable (Double) -> Void
        private var observation: NSKeyValueObservation?
        init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
        func urlSession(_: URLSession, didCreateTask task: URLSessionTask) {
            observation = task.progress.observe(\.fractionCompleted) { [report] p, _ in
                report(p.totalUnitCount > 0 ? p.fractionCompleted : -1)
            }
        }
    }
}

/// Files under Caches (slides, reports, decks — evictable) and Application
/// Support (the last catalog, so the shelf renders before the Mac answers).
struct WeeklyProgressCache: Sendable {
    let cacheRoot: URL
    let catalogFile: URL

    static let maxAge: TimeInterval = 30 * 24 * 60 * 60
    static let maxBytes: Int64 = 250 * 1024 * 1024

    static let standard: WeeklyProgressCache = {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return WeeklyProgressCache(cacheRoot: caches.appendingPathComponent("weekly-progress", isDirectory: true),
                                   catalogFile: support.appendingPathComponent("weekly-progress/catalog-v1.json"))
    }()

    /// A path component that cannot escape the cache directory.
    static func component(_ raw: String) -> String {
        let safe = raw.replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "_", options: .regularExpression)
        return safe.isEmpty || safe.allSatisfy({ $0 == "." }) ? "_" : safe
    }

    func generationDirectory(_ generationID: String) -> URL {
        cacheRoot.appendingPathComponent(Self.component(generationID), isDirectory: true)
    }

    /// Slides live under their asset revision so a resumed run never shows stale renders.
    func slideFile(_ generation: WeeklyProgressGeneration, _ number: Int) -> URL {
        generationDirectory(generation.id)
            .appendingPathComponent(Self.component(generation.assetRevision), isDirectory: true)
            .appendingPathComponent("slide-\(number).png")
    }

    func reportFile(_ generationID: String) -> URL {
        generationDirectory(generationID).appendingPathComponent("research-report.md")
    }

    func deckFile(_ generation: WeeklyProgressGeneration) -> URL {
        generationDirectory(generation.id)
            .appendingPathComponent(Self.component(generation.assetRevision), isDirectory: true)
            .appendingPathComponent(WeeklyProgressFiles.deckFilename(projectName: generation.projectName,
                                                                     weekStart: generation.weekStart))
    }

    func read(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        // Touch so size-based pruning evicts least recently used files first.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    /// Atomic write; for slides, also drops renders of older revisions.
    func write(_ data: Data, to url: URL, replacingSiblingRevisions: Bool = false) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        if replacingSiblingRevisions { removeOtherRevisions(keeping: dir) }
    }

    /// Moves a downloaded file into place.
    func move(_ from: URL, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.removeItem(at: url)
        try fm.moveItem(at: from, to: url)
        removeOtherRevisions(keeping: dir)
    }

    private func removeOtherRevisions(keeping revisionDir: URL) {
        let fm = FileManager.default
        let parent = revisionDir.deletingLastPathComponent()
        guard let siblings = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for s in siblings where s.lastPathComponent != revisionDir.lastPathComponent
            && (try? s.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            try? fm.removeItem(at: s)
        }
    }

    func loadCatalog() -> WeeklyProgressCatalog? {
        guard let data = try? Data(contentsOf: catalogFile) else { return nil }
        return try? WeeklyProgressCatalog.decode(data)
    }

    func saveCatalog(_ raw: Data) {
        try? FileManager.default.createDirectory(at: catalogFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? raw.write(to: catalogFile, options: .atomic)
    }

    /// Deletes files older than `maxAge`, then the least recently used until
    /// the cache fits `maxBytes`, then empty directories.
    func prune(now: Date = Date(), maxAge: TimeInterval = maxAge, maxBytes: Int64 = maxBytes) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let walker = fm.enumerator(at: cacheRoot, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, modified: Date, size: Int64)] = []
        var dirs: [URL] = []
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isRegularFile == true {
                let modified = v.contentModificationDate ?? .distantPast
                if now.timeIntervalSince(modified) > maxAge {
                    try? fm.removeItem(at: url)
                } else {
                    files.append((url, modified, Int64(v.fileSize ?? 0)))
                }
            } else {
                dirs.append(url)
            }
        }
        var total = files.reduce(0) { $0 + $1.size }
        for f in files.sorted(by: { $0.modified < $1.modified }) where total > maxBytes {
            if (try? fm.removeItem(at: f.url)) != nil { total -= f.size }
        }
        // Deepest first, so a directory emptied by its children goes too.
        for dir in dirs.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? fm.removeItem(at: dir) }
        }
    }
}
