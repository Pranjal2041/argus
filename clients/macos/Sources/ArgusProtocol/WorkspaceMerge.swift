import Foundation

/// Same three-way contract as the sync host. Used to rebase edits made while a
/// sync request was in flight. Missing values are deletions, not empty records.
public enum WorkspaceMerge {
    public static func merge(base: ArgusJSON, local: ArgusJSON, remote: ArgusJSON) throws -> ArgusJSON {
        var conflicts: [String] = []
        let result = merge(base, local, remote, path: "", conflicts: &conflicts)
        guard conflicts.isEmpty else { throw ArgusFailure("conflict", "Concurrent workspace edits need review.", details: .array(conflicts.map(ArgusJSON.string))) }
        return result
    }
    private static func merge(_ base: ArgusJSON, _ local: ArgusJSON, _ remote: ArgusJSON,
                              path: String, conflicts: inout [String]) -> ArgusJSON {
        if local == base { return remote }
        if remote == base || local == remote { return local }
        if let l = local.object, let r = remote.object, base == .null || base.object != nil {
            let b = base.object ?? [:]; var out: [String: ArgusJSON] = [:]
            for key in Set(b.keys).union(l.keys).union(r.keys).sorted() {
                let value = merge(b[key] ?? .null, l[key] ?? .null, r[key] ?? .null, path: path + "/" + key, conflicts: &conflicts)
                if value != .null { out[key] = value }
            }
            return .object(out)
        }
        if let l = records(local), let r = records(remote), let b = records(base) {
            let out = Set(b.keys).union(l.keys).union(r.keys).sorted().compactMap { key -> ArgusJSON? in
                let value = merge(b[key] ?? .null, l[key] ?? .null, r[key] ?? .null, path: path + "/" + key, conflicts: &conflicts)
                return value == .null ? nil : value
            }
            return .array(out)
        }
        if path.hasSuffix("/editedAt") || path.hasSuffix("/updatedAt"), let l = local.string, let r = remote.string,
           let ld = ISO8601DateFormatter().date(from: l), let rd = ISO8601DateFormatter().date(from: r) { return ld > rd ? local : remote }
        conflicts.append(path); return remote
    }
    private static func records(_ value: ArgusJSON) -> [String: ArgusJSON]? {
        if value == .null { return [:] }
        guard let values = value.array else { return nil }
        var result: [String: ArgusJSON] = [:]
        for value in values {
            guard let id = value["id"].string, !id.isEmpty, result[id] == nil else { return nil }
            result[id] = value
        }
        return result
    }
}
