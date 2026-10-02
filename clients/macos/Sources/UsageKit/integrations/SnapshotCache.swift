import Foundation

@available(macOS 14.0, *)
struct SnapshotCache: Sendable {
    var url: URL = IntegrationConfiguration.directory.appendingPathComponent("last-readings.json")
    private struct Envelope: Codable { var version = 2; var sources: [UsageSource] }

    func load() -> [UsageSource] {
        guard let data = try? Data(contentsOf: url), data.count <= 8_000_000,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 2 else { return [] }
        return envelope.sources.filter { $0.origin == .live && $0.unavailable == nil }.map { source in
            var source = source; source.isStale = true
            if var storage = source.storage { storage.online = false; source.payload = .storage(storage) }
            return source
        }
    }
    func save(_ sources: [UsageSource]) throws {
        let safe = sources.filter { $0.origin == .live && $0.unavailable == nil }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Envelope(sources: safe)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
