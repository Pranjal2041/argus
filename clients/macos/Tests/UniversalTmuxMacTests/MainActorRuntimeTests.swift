import XCTest
@testable import UniversalTmuxMac

final class MainActorRuntimeTests: XCTestCase {
    func testWatchdogRequiresConsecutiveMissesAndResetsAfterRecovery() {
        var health = MainActorHealth(maximumMisses: 3)
        XCTAssertEqual(health.check(), .probe)
        XCTAssertEqual(health.check(), .wait)
        XCTAssertEqual(health.check(), .wait)
        health.acknowledge()
        XCTAssertEqual(health.misses, 0)
        XCTAssertEqual(health.check(), .probe)
        XCTAssertEqual(health.check(), .wait)
        XCTAssertEqual(health.check(), .wait)
        XCTAssertEqual(health.check(), .stalled)
    }

    func testResponsiveExecutorNeverAccumulatesMissesOrDuplicateProbes() {
        var health = MainActorHealth()
        for _ in 0..<100 {
            XCTAssertEqual(health.check(), .probe)
            health.acknowledge()
            XCTAssertFalse(health.pending)
            XCTAssertEqual(health.misses, 0)
        }
        XCTAssertEqual(health.check(), .probe)
        XCTAssertEqual(health.check(), .wait)
        XCTAssertTrue(health.pending)
    }

    @MainActor func testDeliveryIsAsynchronousEvenWhenPostedFromItsOwnExecutor() async {
        let center = NotificationCenter(), name = Notification.Name("runtime-recovery")
        let received = expectation(description: "recovery delivered")
        var posting = false
        let observer = MainActorNotification.observe(name, center: center) {
            MainActor.preconditionIsolated()
            XCTAssertFalse(posting, "An observer must not execute inside the synchronous post")
            received.fulfill()
        }
        defer { center.removeObserver(observer) }
        posting = true
        center.post(name: name, object: nil)
        posting = false
        await fulfillment(of: [received], timeout: 2)
    }

    @MainActor func testBackgroundPostsAndNestedDeliveryDoNotBlockEitherExecutor() async {
        let center = NotificationCenter(), name = Notification.Name("runtime-policy")
        let received = expectation(description: "both events delivered")
        received.expectedFulfillmentCount = 2
        let posted = expectation(description: "posting returned")
        var count = 0
        let observer = MainActorNotification.observe(name, center: center) {
            MainActor.preconditionIsolated()
            count += 1
            received.fulfill()
            if count == 1 { center.post(name: name, object: nil) }
        }
        defer { center.removeObserver(observer) }
        DispatchQueue.global().async {
            center.post(name: name, object: nil)
            posted.fulfill()
        }
        await fulfillment(of: [posted, received], timeout: 2)
        XCTAssertEqual(count, 2)
    }
}
