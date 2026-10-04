import Foundation
import CryptoKit

public struct EditorDraft: Codable, Equatable, Sendable {
    public var identity: String
    public var path: String
    public var revision: String
    public var base: String
    public var text: String
    public init(identity: String, path: String, revision: String, base: String, text: String) {
        self.identity = identity; self.path = path; self.revision = revision; self.base = base; self.text = text
    }
}

public struct EditorDraftStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    private func file(_ identity: String, _ path: String) -> URL {
        let hash = SHA256.hash(data: Data((identity + "\0" + path).utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }
    public func read(identity: String, path: String) throws -> EditorDraft? {
        let url = file(identity, path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let draft = try JSONDecoder().decode(EditorDraft.self, from: ArgusWire.readFile(url, limit: 48 * 1024 * 1024))
        guard draft.identity == identity, draft.path == path else { throw ArgusFailure("invalid_draft", "Draft identity mismatch.") }
        return draft
    }
    public func save(_ draft: EditorDraft) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = file(draft.identity, draft.path)
        try ArgusWire.encoder().encode(draft).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func remove(identity: String, path: String) throws {
        let url = file(identity, path)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
