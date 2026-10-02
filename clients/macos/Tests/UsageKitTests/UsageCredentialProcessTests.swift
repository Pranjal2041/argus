import XCTest
@testable import UsageKit

@available(macOS 14.0, *)
final class UsageCredentialProcessTests: XCTestCase {
    func testBackgroundReadAndRenewalUseWorkerRatherThanHostKeychain() throws {
        let worker = RecordingCredentialWorker()
        let store = KeychainCredentialStore(worker: worker)
        XCTAssertEqual(try store.read(reference: "fixture"), ["token": "fixture-value"])
        try store.update(["token": "renewed-fixture"], reference: "fixture")
        XCTAssertEqual(worker.requests.map(\.operation), [.read, .update])
        XCTAssertEqual(worker.requests.map(\.reference), ["fixture", "fixture"])
        XCTAssertEqual(worker.requests.last?.values, ["token": "renewed-fixture"])
    }
}

@available(macOS 14.0, *)
private final class RecordingCredentialWorker: UsageCredentialRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [UsageCredentialRequest] = []
    func perform(_ request: UsageCredentialRequest) throws -> UsageCredentialResponse {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return UsageCredentialResponse(values: ["token": "fixture-value"])
    }
}
