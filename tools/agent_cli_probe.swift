// Compile with the production AgentCLI, AgentProvider, BoundedProcessRunner and
// CodexModels sources. Runs isolated capability checks; never opens the desktop app.
import Foundation

@main
struct AgentCLIProbe {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let name = arguments.first, let provider = AgentProvider(rawValue: name),
              arguments.count == 1 || (arguments.count == 2 && arguments[1] == "--workspace")
                || (arguments.count == 3 && arguments[1] == "--image") else {
            throw NSError(domain: "AgentCLIProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "usage: agent-cli-probe <claude|codex|devin> [--workspace | --image PATH]"])
        }
        do {
            let runner = AgentCLIRunner()
            if arguments.count == 2 {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("argus-workspace-probe-\(UUID())")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let file = directory.appendingPathComponent("check.txt")
                let first = try await runner.run(AgentGenerationRequest(provider: provider, purpose: .weeklyProgress,
                    prompt: "This is an isolated Argus integration test. Write exactly ARGUS_WRITE_OK into check.txt in the current directory. Do not access other directories or use the network. Then reply with exactly ARGUS_WRITE_OK.",
                    directory: directory, timeout: 90,
                    diagnosticsPrefix: FileManager.default.temporaryDirectory.appendingPathComponent("argus-workspace-probe-initial")))
                let firstContent = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                guard firstContent == "ARGUS_WRITE_OK" else {
                    throw NSError(domain: "AgentCLIProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Initial workspace check wrote unexpected content: \(firstContent.prefix(200)); final answer: \(first.text.prefix(500))"])
                }
                let second = try await runner.run(AgentGenerationRequest(provider: provider, purpose: .weeklyProgress,
                    prompt: "Replace check.txt in the current directory with exactly ARGUS_REWRITE_OK. Do not access other directories or use the network. Then reply with exactly ARGUS_REWRITE_OK.",
                    conversation: first.conversation, directory: directory, timeout: 90,
                    diagnosticsPrefix: FileManager.default.temporaryDirectory.appendingPathComponent("argus-workspace-probe-resume")))
                let secondContent = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                guard secondContent == "ARGUS_REWRITE_OK", first.conversation == second.conversation else {
                    throw NSError(domain: "AgentCLIProbe", code: 4, userInfo: [NSLocalizedDescriptionKey: "Resumed workspace check wrote unexpected content: \(secondContent.prefix(200)); final answer: \(second.text.prefix(500))"])
                }
                print("\(provider.rawValue): sandboxed workspace write and explicit-resume rewrite verified")
                return
            }
            if arguments.count == 3 {
                let result = try await runner.run(AgentGenerationRequest(provider: provider, purpose: .artifactTitle,
                    prompt: "Inspect the attached screenshot using the read tool. What section heading appears above the provider choices? Reply only with the heading.",
                    imageURL: URL(fileURLWithPath: arguments[2]), timeout: 90))
                guard result.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ai providers" else { throw AgentCLIError.missingResult }
                print("\(provider.rawValue): attached-image reading verified")
                return
            }
            let initial = try await runner.run(AgentGenerationRequest(provider: provider, purpose: .status,
                prompt: "This is an Argus integration check. Do not use tools. Reply with exactly ARGUS_START_OK.", timeout: 60))
            guard initial.text.trimmingCharacters(in: .whitespacesAndNewlines) == "ARGUS_START_OK" else { throw AgentCLIError.missingResult }
            let resumed = try await runner.run(AgentGenerationRequest(provider: provider, purpose: .status,
                prompt: "Do not use tools. Reply with exactly ARGUS_RESUME_OK.", conversation: initial.conversation, timeout: 60))
            guard resumed.text.trimmingCharacters(in: .whitespacesAndNewlines) == "ARGUS_RESUME_OK",
                  initial.conversation == resumed.conversation else { throw AgentCLIError.invalidConversation }
            print("\(provider.rawValue): initial and explicit-resume final answers verified")
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
