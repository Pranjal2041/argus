import Foundation

enum ArtifactKind {
    static let renderPDF = "render-pdf"
    static let screenshotPNG = "screenshot-png"
    static let fileSnapshot = "file-snapshot"
}

/// The identity captured at the moment Render opens.  Keeping this alongside
/// the PDF means the library survives panel removal, host outages, and session
/// renames instead of depending on whatever happens to be live later.
struct ArtifactPanelContext: Codable, Hashable {
    let machineID: String
    let machineName: String
    let machineHost: String
    let sessionName: String
    let stableSessionID: String?
    let folder: String

    /// tmux ids survive renames.  Backends without one (notably ConPTY) fall
    /// back to the session name they expose.
    var key: String {
        if let stableSessionID, !stableSessionID.isEmpty {
            return machineID + "/id:" + stableSessionID
        }
        return machineID + "/name:" + sessionName
    }
}

struct ArtifactRecord: Codable, Identifiable, Hashable {
    let schemaVersion: Int
    let id: UUID
    var filename: String
    let createdAt: Date
    let kind: String
    let panel: ArtifactPanelContext
    let presentation: String
    let relativePath: String
    let byteCount: Int64
    /// Populated for explicit snapshots created from Files. Optional fields keep
    /// existing V1 render/screenshot manifests fully backwards compatible.
    let sourcePath: String?
    let contentType: String?

    init(
        id: UUID = UUID(),
        filename: String,
        createdAt: Date = Date(),
        kind: String = ArtifactKind.renderPDF,
        panel: ArtifactPanelContext,
        presentation: String,
        relativePath: String,
        byteCount: Int64,
        sourcePath: String? = nil,
        contentType: String? = nil
    ) {
        schemaVersion = 1
        self.id = id
        self.filename = filename
        self.createdAt = createdAt
        self.kind = kind
        self.panel = panel
        self.presentation = presentation
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sourcePath = sourcePath
        self.contentType = contentType
    }

    var isImage: Bool {
        kind == ArtifactKind.screenshotPNG
            || contentType?.lowercased().hasPrefix("image/") == true
            || ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "ico", "icns"]
                .contains(fileExtension)
    }

    var isPDF: Bool { fileExtension == "pdf" || contentType?.lowercased() == "application/pdf" }
    var isMarkdown: Bool {
        let mediaType = contentType?
            .lowercased()
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return mediaType == "text/markdown"
            || mediaType == "text/x-markdown"
            || ["md", "markdown", "mdown", "mkd"].contains(fileExtension)
    }
    var isFileSnapshot: Bool { kind == ArtifactKind.fileSnapshot }

    var fileExtension: String {
        let ext = (relativePath as NSString).pathExtension.lowercased()
        if !ext.isEmpty { return ext }
        if kind == ArtifactKind.screenshotPNG { return "png" }
        return kind == ArtifactKind.renderPDF ? "pdf" : ""
    }
}

enum ArtifactSortOrder: String, CaseIterable, Identifiable {
    case newest
    case oldest
    case nameAscending
    case nameDescending

    var id: String { rawValue }
    var title: String {
        switch self {
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .nameAscending: return "Name A–Z"
        case .nameDescending: return "Name Z–A"
        }
    }
}

struct ArtifactPanelSummary: Identifiable, Hashable {
    let context: ArtifactPanelContext
    let count: Int
    let lastSavedAt: Date
    var id: String { context.key }
}

/// Pure library projections, kept out of SwiftUI so search/order behavior is
/// deterministic and straightforward to regression-test.
enum ArtifactLibraryQuery {
    static func records(
        _ records: [ArtifactRecord],
        panelKey: String? = nil,
        filenameQuery: String = "",
        sort: ArtifactSortOrder = .newest
    ) -> [ArtifactRecord] {
        let needle = filenameQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = records.filter { record in
            (panelKey == nil || record.panel.key == panelKey)
                && (needle.isEmpty || record.filename.localizedCaseInsensitiveContains(needle))
        }
        return filtered.sorted { lhs, rhs in
            switch sort {
            case .newest:
                return lhs.createdAt == rhs.createdAt
                    ? lhs.id.uuidString < rhs.id.uuidString
                    : lhs.createdAt > rhs.createdAt
            case .oldest:
                return lhs.createdAt == rhs.createdAt
                    ? lhs.id.uuidString < rhs.id.uuidString
                    : lhs.createdAt < rhs.createdAt
            case .nameAscending:
                let comparison = lhs.filename.localizedCaseInsensitiveCompare(rhs.filename)
                return comparison == .orderedSame ? lhs.createdAt > rhs.createdAt : comparison == .orderedAscending
            case .nameDescending:
                let comparison = lhs.filename.localizedCaseInsensitiveCompare(rhs.filename)
                return comparison == .orderedSame ? lhs.createdAt > rhs.createdAt : comparison == .orderedDescending
            }
        }
    }

    static func panels(
        _ records: [ArtifactRecord],
        sort: ArtifactSortOrder = .newest
    ) -> [ArtifactPanelSummary] {
        let groups: [ArtifactPanelSummary] = Dictionary(grouping: records, by: { $0.panel.key })
            .values.compactMap { group -> ArtifactPanelSummary? in
                guard let latest = group.max(by: { $0.createdAt < $1.createdAt }) else { return nil }
                return ArtifactPanelSummary(
                    context: latest.panel,
                    count: group.count,
                    lastSavedAt: latest.createdAt
                )
            }
        return groups.sorted { lhs, rhs in
            let nameComparison = lhs.context.sessionName.localizedCaseInsensitiveCompare(rhs.context.sessionName)
            switch sort {
            case .newest:
                return lhs.lastSavedAt == rhs.lastSavedAt
                    ? nameComparison == .orderedAscending
                    : lhs.lastSavedAt > rhs.lastSavedAt
            case .oldest:
                return lhs.lastSavedAt == rhs.lastSavedAt
                    ? nameComparison == .orderedAscending
                    : lhs.lastSavedAt < rhs.lastSavedAt
            case .nameAscending:
                return nameComparison == .orderedSame
                    ? lhs.lastSavedAt > rhs.lastSavedAt
                    : nameComparison == .orderedAscending
            case .nameDescending:
                return nameComparison == .orderedSame
                    ? lhs.lastSavedAt > rhs.lastSavedAt
                    : nameComparison == .orderedDescending
            }
        }
    }
}

enum ArtifactFilename {
    static func generated(
        for panel: ArtifactPanelContext,
        at date: Date,
        fileExtension: String = "pdf"
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return normalized(
            panel.sessionName + " — " + formatter.string(from: date),
            fileExtension: fileExtension
        )
    }

    static func normalized(_ raw: String, fileExtension: String = "pdf") -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for scalar in ["/", ":", "\n", "\r", "\t"] {
            name = name.replacingOccurrences(of: scalar, with: "-")
        }
        while name.contains("  ") { name = name.replacingOccurrences(of: "  ", with: " ") }
        if name.isEmpty { name = "Render" }
        let ext = safeExtension(fileExtension)
        let suppliedExtension = (name as NSString).pathExtension
        // Generated capture names end in a timestamp (`12.00.02`) before their
        // real extension is appended. Do not mistake the final seconds for an
        // extension; do replace actual extensions supplied during Rename.
        let suppliedLooksLikeType = suppliedExtension.unicodeScalars.contains {
            CharacterSet.letters.contains($0)
        }
        if !suppliedExtension.isEmpty,
           suppliedExtension.caseInsensitiveCompare(ext) == .orderedSame || suppliedLooksLikeType {
            name = (name as NSString).deletingPathExtension
        }
        if !ext.isEmpty { name += "." + ext }
        if name.count > 180 {
            let suffix = ext.isEmpty ? "" : "." + ext
            name = String(name.prefix(max(1, 180 - suffix.count)))
                .trimmingCharacters(in: .whitespaces) + suffix
        }
        return name
    }

    /// Preserve the source file's useful name and extension while removing path
    /// separators/control characters. Extension filtering also prevents a remote
    /// filename from escaping the immutable UUID blob path on disk.
    static func snapshot(_ sourceName: String) -> String {
        let ext = safeExtension((sourceName as NSString).pathExtension)
        return normalized(sourceName, fileExtension: ext)
    }

    static func safeExtension(_ raw: String) -> String {
        String(raw.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.prefix(24))
    }
}

enum ArtifactDiskError: LocalizedError {
    case unsafePath

    var errorDescription: String? {
        switch self {
        case .unsafePath: return "The artifact record contains an unsafe file path."
        }
    }
}

/// Files are immutable UUID-named blobs with one small JSON manifest each.
/// This avoids a single ever-growing index becoming a corruption or contention
/// point, while keeping future artifact kinds possible without changing V1 UI.
actor ArtifactDiskStore {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func load() throws -> [ArtifactRecord] {
        try prepareDirectories()
        let urls = try FileManager.default.contentsOfDirectory(
            at: recordsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "json",
                  let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(ArtifactRecord.self, from: data),
                  record.schemaVersion == 1,
                  let contentURL = try? self.contentURL(for: record),
                  FileManager.default.fileExists(atPath: contentURL.path)
            else { return nil }
            return record
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func savePDF(
        _ data: Data,
        panel: ArtifactPanelContext,
        presentation: String,
        createdAt: Date = Date(),
        id: UUID = UUID()
    ) throws -> ArtifactRecord {
        try prepareDirectories()
        let relativePath = "pdf/" + id.uuidString.lowercased() + ".pdf"
        // The manifest's ISO-8601 strategy persists whole seconds. Normalize
        // up front so the in-memory record and a record loaded after relaunch
        // are identical (the UI and generated filename are second-granular).
        let persistedCreatedAt = Date(timeIntervalSince1970: floor(createdAt.timeIntervalSince1970))
        let record = ArtifactRecord(
            id: id,
            filename: ArtifactFilename.generated(for: panel, at: persistedCreatedAt, fileExtension: "pdf"),
            createdAt: persistedCreatedAt,
            kind: ArtifactKind.renderPDF,
            panel: panel,
            presentation: presentation,
            relativePath: relativePath,
            byteCount: Int64(data.count)
        )
        let pdfURL = try contentURL(for: record)
        do {
            try data.write(to: pdfURL, options: .atomic)
            try writeManifest(record)
            return record
        } catch {
            try? FileManager.default.removeItem(at: pdfURL)
            throw error
        }
    }

    func saveScreenshotPNG(
        _ data: Data,
        panel: ArtifactPanelContext,
        createdAt: Date = Date(),
        id: UUID = UUID()
    ) throws -> ArtifactRecord {
        try prepareDirectories()
        let relativePath = "images/" + id.uuidString.lowercased() + ".png"
        let persistedCreatedAt = Date(timeIntervalSince1970: floor(createdAt.timeIntervalSince1970))
        let record = ArtifactRecord(
            id: id,
            filename: ArtifactFilename.generated(
                for: panel,
                at: persistedCreatedAt,
                fileExtension: "png"
            ),
            createdAt: persistedCreatedAt,
            kind: ArtifactKind.screenshotPNG,
            panel: panel,
            presentation: "clipboard-screenshot",
            relativePath: relativePath,
            byteCount: Int64(data.count)
        )
        let imageURL = try contentURL(for: record)
        do {
            try data.write(to: imageURL, options: .atomic)
            try writeManifest(record)
            return record
        } catch {
            try? FileManager.default.removeItem(at: imageURL)
            throw error
        }
    }

    func saveFile(
        _ data: Data,
        filename: String,
        panel: ArtifactPanelContext,
        sourcePath: String,
        contentType: String?,
        presentation: String,
        createdAt: Date = Date(),
        id: UUID = UUID()
    ) throws -> ArtifactRecord {
        try prepareDirectories()
        let record = fileRecord(
            filename: filename,
            byteCount: Int64(data.count),
            panel: panel,
            sourcePath: sourcePath,
            contentType: contentType,
            presentation: presentation,
            createdAt: createdAt,
            id: id
        )
        let destination = try contentURL(for: record)
        do {
            try data.write(to: destination, options: .atomic)
            try writeManifest(record)
            return record
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Streamed variant used for files that are not already visible in the Files
    /// editor. URLSession owns the temporary download; copy it into the immutable
    /// artifact store before that temporary file goes out of scope.
    func saveFile(
        at sourceURL: URL,
        filename: String,
        panel: ArtifactPanelContext,
        sourcePath: String,
        contentType: String?,
        presentation: String,
        createdAt: Date = Date(),
        id: UUID = UUID()
    ) throws -> ArtifactRecord {
        try prepareDirectories()
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let record = fileRecord(
            filename: filename,
            byteCount: byteCount,
            panel: panel,
            sourcePath: sourcePath,
            contentType: contentType,
            presentation: presentation,
            createdAt: createdAt,
            id: id
        )
        let destination = try contentURL(for: record)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            try writeManifest(record)
            return record
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func rename(_ record: ArtifactRecord, to requestedName: String) throws -> ArtifactRecord {
        var updated = record
        updated.filename = ArtifactFilename.normalized(
            requestedName,
            fileExtension: record.fileExtension
        )
        try writeManifest(updated)
        return updated
    }

    func delete(_ record: ArtifactRecord) throws {
        let manifest = manifestURL(for: record.id)
        let content = try contentURL(for: record)
        if FileManager.default.fileExists(atPath: manifest.path) {
            try FileManager.default.removeItem(at: manifest)
        }
        if FileManager.default.fileExists(atPath: content.path) {
            try FileManager.default.removeItem(at: content)
        }
    }

    private var recordsURL: URL { rootURL.appendingPathComponent("records", isDirectory: true) }
    private var pdfURL: URL { rootURL.appendingPathComponent("pdf", isDirectory: true) }
    private var imagesURL: URL { rootURL.appendingPathComponent("images", isDirectory: true) }
    private var filesURL: URL { rootURL.appendingPathComponent("files", isDirectory: true) }

    private func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: recordsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pdfURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: filesURL, withIntermediateDirectories: true)
    }

    private func fileRecord(
        filename: String,
        byteCount: Int64,
        panel: ArtifactPanelContext,
        sourcePath: String,
        contentType: String?,
        presentation: String,
        createdAt: Date,
        id: UUID
    ) -> ArtifactRecord {
        let persistedCreatedAt = Date(timeIntervalSince1970: floor(createdAt.timeIntervalSince1970))
        let ext = ArtifactFilename.safeExtension((filename as NSString).pathExtension)
        let suffix = ext.isEmpty ? "" : "." + ext
        return ArtifactRecord(
            id: id,
            filename: ArtifactFilename.snapshot(filename),
            createdAt: persistedCreatedAt,
            kind: ArtifactKind.fileSnapshot,
            panel: panel,
            presentation: presentation,
            relativePath: "files/" + id.uuidString.lowercased() + suffix,
            byteCount: byteCount,
            sourcePath: sourcePath,
            contentType: contentType
        )
    }

    private func manifestURL(for id: UUID) -> URL {
        recordsURL.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    private func contentURL(for record: ArtifactRecord) throws -> URL {
        guard !record.relativePath.hasPrefix("/"), !record.relativePath.contains("..") else {
            throw ArtifactDiskError.unsafePath
        }
        let candidate = rootURL.appendingPathComponent(record.relativePath).standardizedFileURL
        let rootPath = rootURL.standardizedFileURL.path + "/"
        guard candidate.path.hasPrefix(rootPath) else { throw ArtifactDiskError.unsafePath }
        return candidate
    }

    private func writeManifest(_ record: ArtifactRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: manifestURL(for: record.id), options: .atomic)
    }
}

@MainActor
final class ArtifactStore: ObservableObject {
    nonisolated static var defaultRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Argus/artifacts", isDirectory: true)
    }

    @Published private(set) var records: [ArtifactRecord] = []
    @Published private(set) var isLoading = true
    @Published var errorMessage: String?
    @Published var selectedPanelKey: String?
    @Published var selectedPanelContext: ArtifactPanelContext?
    @Published var selectedArtifactID: UUID?
    @Published var query = ""
    @Published var sortOrder: ArtifactSortOrder = .newest

    let rootURL: URL
    private let disk: ArtifactDiskStore
    private let logEvents: Bool

    init(
        rootURL: URL = ArtifactStore.defaultRootURL,
        loadImmediately: Bool = true,
        logEvents: Bool = true
    ) {
        self.rootURL = rootURL
        disk = ArtifactDiskStore(rootURL: rootURL)
        self.logEvents = logEvents && !AppState.isRunningTests
        if loadImmediately {
            Task { await reload() }
        } else {
            isLoading = false
        }
    }

    var selectedArtifact: ArtifactRecord? {
        guard let selectedArtifactID else { return nil }
        return records.first { $0.id == selectedArtifactID }
    }

    func fileURL(for record: ArtifactRecord) -> URL {
        rootURL.appendingPathComponent(record.relativePath)
    }

    func count(for panelKey: String) -> Int {
        records.lazy.filter { $0.panel.key == panelKey }.count
    }

    func openLibrary() {
        selectedArtifactID = nil
        selectedPanelKey = nil
        selectedPanelContext = nil
        query = ""
    }

    func open(panel: ArtifactPanelContext) {
        selectedArtifactID = nil
        selectedPanelKey = panel.key
        selectedPanelContext = panel
        query = ""
    }

    func open(artifact: ArtifactRecord) {
        selectedPanelKey = artifact.panel.key
        selectedPanelContext = artifact.panel
        selectedArtifactID = artifact.id
        query = ""
    }

    func reload() async {
        isLoading = true
        do {
            records = try await disk.load()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func savePDF(
        _ data: Data,
        panel: ArtifactPanelContext,
        presentation: String
    ) async throws -> ArtifactRecord {
        let record = try await disk.savePDF(data, panel: panel, presentation: presentation)
        publish(record)
        return record
    }

    func saveScreenshotPNG(
        _ data: Data,
        panel: ArtifactPanelContext
    ) async throws -> ArtifactRecord {
        let record = try await disk.saveScreenshotPNG(data, panel: panel)
        publish(record)
        return record
    }

    func saveFile(
        _ data: Data,
        filename: String,
        panel: ArtifactPanelContext,
        sourcePath: String,
        contentType: String?,
        presentation: String
    ) async throws -> ArtifactRecord {
        let record = try await disk.saveFile(
            data,
            filename: filename,
            panel: panel,
            sourcePath: sourcePath,
            contentType: contentType,
            presentation: presentation
        )
        publish(record)
        return record
    }

    func saveFile(
        at sourceURL: URL,
        filename: String,
        panel: ArtifactPanelContext,
        sourcePath: String,
        contentType: String?,
        presentation: String
    ) async throws -> ArtifactRecord {
        let record = try await disk.saveFile(
            at: sourceURL,
            filename: filename,
            panel: panel,
            sourcePath: sourcePath,
            contentType: contentType,
            presentation: presentation
        )
        publish(record)
        return record
    }

    func rename(_ record: ArtifactRecord, to name: String) async throws -> ArtifactRecord {
        let updated = try await disk.rename(record, to: name)
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = updated
        }
        errorMessage = nil
        return updated
    }

    func delete(_ record: ArtifactRecord) async throws {
        try await disk.delete(record)
        records.removeAll { $0.id == record.id }
        if selectedArtifactID == record.id { selectedArtifactID = nil }
        errorMessage = nil
    }

    private func publish(_ record: ArtifactRecord) {
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        errorMessage = nil
        guard logEvents else { return }
        var fields: [String: Any] = [
            "artifactID": record.id.uuidString.lowercased(),
            "filename": record.filename,
            "kind": record.kind,
            "machineID": record.panel.machineID,
            "machine": record.panel.machineName,
            "session": record.panel.sessionName,
            "panelKey": record.panel.key,
            "presentation": record.presentation,
        ]
        if !record.panel.folder.isEmpty { fields["folder"] = record.panel.folder }
        if let sourcePath = record.sourcePath { fields["sourcePath"] = sourcePath }
        if let contentType = record.contentType { fields["contentType"] = contentType }
        ActivityJournal.shared.log("artifactSaved", fields)
    }
}
