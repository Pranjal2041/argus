import XCTest
@testable import UniversalTmuxMac

final class BoundedProcessRunnerTests: XCTestCase {
    func testInputAndOutputDrainConcurrently() async throws {
        let input = Data(repeating: 65, count: 150_000)
        let result = try await BoundedProcessRunner(timeout: 3).run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], input: input)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, input)
    }

    func testUncooperativeChildCannotHoldAQueueSlotForever() async {
        let began = Date()
        do {
            _ = try await BoundedProcessRunner(timeout: 0.1, terminationGrace: 0.1).run(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; exec /bin/sleep 60"])
            XCTFail("expected timeout")
        } catch BoundedProcessRunner.Failure.timedOut {} catch { XCTFail("\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(began), 3)
    }

    func testCancellationTerminatesOnlyItsOwnedChild() async {
        let task = Task {
            try await BoundedProcessRunner(timeout: 30, terminationGrace: 0.1).run(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; exec /bin/sleep 60"])
        }
        try? await Task.sleep(for: .milliseconds(100))
        let began = Date(); task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(began), 3)
    }

    func testOutputBoundStopsAnUnboundedProducer() async {
        do {
            _ = try await BoundedProcessRunner(timeout: 3, terminationGrace: 0.1, maximumOutputBytes: 1024).run(
                executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [])
            XCTFail("expected output limit")
        } catch BoundedProcessRunner.Failure.oversizedOutput {} catch { XCTFail("\(error)") }
    }

    func testDescendantHoldingStdoutDoesNotExtendTheCompletedParentsLifetime() async throws {
        let began = Date()
        let result = try await BoundedProcessRunner(timeout: 0.5).run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "/bin/sleep 3 & exit 0"])
        XCTAssertEqual(result.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(began), 2)
    }

    func testDescendantNotReadingStdinDoesNotBlockTheCompletedParent() async throws {
        let began = Date()
        let result = try await BoundedProcessRunner(timeout: 0.5).run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "/bin/sleep 3 <&0 & exit 0"],
            input: Data(repeating: 65, count: 150_000))
        XCTAssertEqual(result.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(began), 2)
    }
}
