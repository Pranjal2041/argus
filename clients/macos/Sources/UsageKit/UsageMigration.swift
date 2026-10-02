import Foundation

@available(macOS 14.0, *)
enum UsageMigration {
    /// Import references, not secrets. The old config/cache and Keychain entries
    /// remain owned by Usage; reconnecting in Argus never deletes an imported key.
    static func importIfNeeded(from legacy: URL, to destination: URL) throws -> Bool {
        let fm = FileManager.default
        let target = destination.appendingPathComponent("integrations.json")
        let old = legacy.appendingPathComponent("integrations.json")
        guard !fm.fileExists(atPath: target.path), fm.fileExists(atPath: old.path) else { return false }
        let configuration = try IntegrationConfiguration.load(from: old)
        try configuration.save(to: target)
        let readings = SnapshotCache(url: legacy.appendingPathComponent("last-readings.json")).load()
        if !readings.isEmpty { try SnapshotCache(url: destination.appendingPathComponent("last-readings.json")).save(readings) }
        return true
    }
}
