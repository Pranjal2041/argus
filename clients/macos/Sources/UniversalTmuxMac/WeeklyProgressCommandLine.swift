import Darwin
import Dispatch
import Foundation

struct WeeklyProgressCommandRequest: Codable, Hashable {
    var project: WeeklyProgressProject
    var weekContaining: Date
    var journalDirectory: String?
    var storeDirectory: String?
}

enum WeeklyProgressCommandLine {
    enum Operation: Equatable {
        case generate(URL)
        case resume(URL)
    }

    static func operation(arguments: [String]) -> Operation? {
        guard arguments.count == 3 else { return nil }
        let url = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        switch arguments[1] {
        case "--weekly-progress-generate": return .generate(url)
        case "--weekly-progress-resume": return .resume(url)
        default: return nil
        }
    }

    /// A headless bridge for exercising the exact app pipeline before its final
    /// browsing/configuration UI exists. Directly executing the Argus binary with
    /// one of the private flags never starts SwiftUI.
    static func launch(_ operation: Operation) -> Never {
        Task.detached(priority: .userInitiated) {
            do {
                let generation: WeeklyProgressGeneration
                switch operation {
                case .generate(let requestURL):
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let request = try decoder.decode(
                        WeeklyProgressCommandRequest.self,
                        from: Data(contentsOf: requestURL)
                    )
                    let store = request.storeDirectory.map {
                        WeeklyProgressDiskStore(rootURL: URL(fileURLWithPath: $0))
                    } ?? WeeklyProgressDiskStore()
                    let journal = request.journalDirectory.map(URL.init(fileURLWithPath:))
                        ?? ActivityJournal.dirURL
                    let pipeline = WeeklyProgressPipeline(
                        store: store,
                        journalDirectory: journal
                    )
                    generation = try await pipeline.generate(
                        project: request.project,
                        week: WeeklyProgressWeek(containing: request.weekContaining)
                    )
                case .resume(let generationDirectory):
                    let pipeline = WeeklyProgressPipeline()
                    generation = try await pipeline.resume(
                        generationDirectory: generationDirectory
                    )
                }
                writeStandardOutput(generation)
                fflush(stdout)
                exit(EXIT_SUCCESS)
            } catch {
                let message = "weekly progress failed: \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(message.utf8))
                fflush(stderr)
                exit(EXIT_FAILURE)
            }
        }
        dispatchMain()
    }

    private static func writeStandardOutput(_ generation: WeeklyProgressGeneration) {
        let payload: [String: Any] = [
            "generation": generation.directory.path,
            "state": generation.manifest.stage.rawValue,
            "project": generation.manifest.project.name,
            "week": generation.manifest.week.storageKey,
            "finalDeck": generation.directory.appendingPathComponent("weekly-progress.pptx").path,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        FileHandle.standardOutput.write(data + Data([0x0a]))
    }
}
