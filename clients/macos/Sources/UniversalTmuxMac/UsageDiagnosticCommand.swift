import Foundation
import UsageKit

enum UsageDiagnosticCommand {
    static func runIfRequested() {
        guard let index = CommandLine.arguments.firstIndex(of: "--usage-diagnostic") else { return }
        guard #available(macOS 14.0, *), CommandLine.arguments.indices.contains(index + 1) else { exit(2) }
        let sourceID = CommandLine.arguments[index + 1]
        Task {
            do {
                let result = try await UsageCollectionDiagnostic.collect(sourceID: sourceID)
                FileHandle.standardOutput.write(result + Data("\n".utf8))
                exit(0)
            } catch {
                // A diagnostic never prints a raw provider response or credentials.
                FileHandle.standardError.write(Data("Usage diagnostic could not load the requested connection.\n".utf8))
                exit(1)
            }
        }
        HeadlessMainRunLoop.run()
    }
}
