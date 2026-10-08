import XCTest
import Security
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

    func testCredentialFailuresKeepTheirCategoryAcrossTheWorkerBoundary() throws {
        for original in [IntegrationError.unavailable("Temporary service interruption"), .permission("Locked"),
                         .invalidResponse("Invalid worker data"), .timeout, .authentication("Missing saved credential")] {
            let data = try JSONEncoder().encode(UsageCredentialResponse.failure(original))
            let response = try JSONDecoder().decode(UsageCredentialResponse.self, from: data)
            XCTAssertThrowsError(try response.validate()) { error in
                XCTAssertEqual((error as? IntegrationError)?.needsAuthentication, original.needsAuthentication)
                XCTAssertEqual((error as? IntegrationError)?.title, original.title)
            }
        }
        let legacy = UsageCredentialResponse(error: "A worker from an earlier build returned an error")
        XCTAssertThrowsError(try legacy.validate()) { error in
            XCTAssertEqual((error as? IntegrationError)?.needsAuthentication, false)
        }
    }

    func testKeychainStatusDoesNotTurnEveryFailureIntoAnAuthenticationFailure() {
        for status in [errSecNotAvailable, errSecIO, errSecDecode, errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled] {
            XCTAssertFalse(KeychainCredentialStore.failure(for: status).needsAuthentication)
        }
        XCTAssertTrue(KeychainCredentialStore.failure(for: errSecItemNotFound).needsAuthentication)
    }

    func testWorkerIgnoringTerminationStillHasABoundedDeadline() throws {
        let script = try fixture("#!/bin/sh\ntrap '' TERM\nexec /bin/sleep 60\n")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let worker = UsageCredentialProcess(executable: script, timeout: 0.15, terminationGrace: 0.05)
        let start = Date()
        XCTAssertThrowsError(try worker.perform(.init(operation: .read, reference: "fixture"))) { error in
            XCTAssertEqual((error as? IntegrationError)?.errorDescription, IntegrationError.timeout.errorDescription)
            XCTAssertEqual((error as? IntegrationError)?.needsAuthentication, false)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testMalformedWorkerResponseIsNotASignInRequest() throws {
        let script = try fixture("#!/bin/sh\n/usr/bin/printf 'not-json'\n")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        XCTAssertThrowsError(try UsageCredentialProcess(executable: script).perform(.init(operation: .read, reference: "fixture"))) { error in
            XCTAssertEqual((error as? IntegrationError)?.needsAuthentication, false)
            XCTAssertEqual((error as? IntegrationError)?.title, "Unavailable")
        }
    }

    private func fixture(_ source: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("credential-worker-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("worker")
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
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
