import Foundation

@available(macOS 14.0, *)
struct LiveWindowsStorageIntegration: UsageIntegration {
    let id = IntegrationID.windowsStorage
    let configuration: SourceConfiguration
    let executable: String
    var runner: any CommandRunning = CommandRunner()
    var descriptor: IntegrationDescriptor? { configuration.descriptor }

    /// Kept constant, encoded as UTF-16LE, and sent as arguments. No user text becomes PowerShell code.
    static let script = "Get-CimInstance Win32_LogicalDisk | Select-Object DeviceID,VolumeName,DriveType,Size,FreeSpace | ConvertTo-Json -Compress"

    func fetchSources() async throws -> [UsageSource] {
        guard let host = configuration.host, host.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
            throw IntegrationError.configuration("Set a valid UT machine name for Windows storage.")
        }
        let encoded = Self.script.data(using: .utf16LittleEndian)!.base64EncodedString()
        let result = try await runner.run(executable: executable, arguments: ["exec", "@" + host, "powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded], environment: [:], timeout: 20)
        guard result.status == 0 else { throw IntegrationError.unavailable("Windows is unreachable through UT. Showing the last successful reading when available.") }
        let raw = try JSONValue.decode(result.stdout)
        let drives = try Self.normalize(raw)
        return [UsageSource(id: configuration.id, integration: .windowsStorage, account: configuration.label, observedAt: .now,
                            payload: .storage(StorageUsage(online: true, drives: drives)), origin: .live,
                            notes: ["Read-only Win32_LogicalDisk readings through UT (\(host)). Fixed logical drives may include virtual/cloud mounts; their capacities are not added together."])]
    }

    static func normalize(_ raw: JSONValue) throws -> [StorageDrive] {
        let rows = raw.array ?? (raw.object != nil ? [raw] : [])
        let drives: [StorageDrive] = try rows.filter { $0["DriveType"].int == 3 }.map { row in
            guard let id = row["DeviceID"].string, let total = row["Size"].double, let free = row["FreeSpace"].double,
                  total.isFinite, free.isFinite, total > 0, free >= 0, free <= total else {
                throw IntegrationError.invalidResponse("Windows returned an invalid drive capacity.")
            }
            let label = row["VolumeName"].string ?? ""
            return StorageDrive(id: id, name: label.isEmpty ? id : "\(id) · \(label)", usedGB: (total - free) / 1e9,
                                capacityGB: total / 1e9, breakdown: [], historyGB: [])
        }
        guard !drives.isEmpty else { throw IntegrationError.unavailable("Windows did not report any fixed drives.") }
        return drives.sorted { $0.id < $1.id }
    }
}
