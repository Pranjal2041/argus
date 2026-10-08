import Foundation
import CryptoKit
import ArgusProtocol

enum WorkspaceBlobs {
    static let limit = 128 * 1024 * 1024
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func valid(_ hash: String) -> Bool { hash.count == 64 && hash.allSatisfy { "0123456789abcdef".contains($0) } }
    static func upload(_ data: Data, base: String) async throws -> String {
        guard data.count <= limit else { throw ArgusFailure("blob_too_large", "Shared files are limited to 128 MiB.") }
        let hash = hash(data)
        let url = try endpoint(base, hash)
        var probe = URLRequest(url: url); probe.httpMethod = "HEAD"; probe.timeoutInterval = 15
        if let (_, response) = try? await brokerSession.data(for: probe), (response as? HTTPURLResponse)?.statusCode == 200 { return hash }
        var request = URLRequest(url: url); request.httpMethod = "PUT"; request.timeoutInterval = 180; request.httpBody = data
        let (_, response) = try await brokerSession.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw ArgusFailure("blob_upload_failed", "The workspace did not acknowledge the file upload.")
        }
        return hash
    }
    static func download(_ hash: String, base: String) async throws -> Data {
        guard valid(hash) else { throw ArgusFailure("invalid_blob", "Invalid shared file reference.") }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Argus/workspace-blobs")
        let file = cache.appendingPathComponent(hash)
        if let data = try? Data(contentsOf: file), self.hash(data) == hash { return data }
        var request = URLRequest(url: try endpoint(base, hash)); request.timeoutInterval = 180
        let (data, response) = try await brokerSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= limit, self.hash(data) == hash else {
            throw ArgusFailure("blob_integrity_failed", "The shared file could not be verified. The local copy is unchanged.")
        }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return data
    }
    private static func endpoint(_ base: String, _ hash: String) throws -> URL {
        guard valid(hash), let url = URL(string: base + "/workspace/blobs/" + hash) else { throw ArgusFailure("invalid_blob", "Invalid shared file reference.") }
        return url
    }
}
