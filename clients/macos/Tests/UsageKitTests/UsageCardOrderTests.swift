import XCTest
@testable import UsageKit

@available(macOS 14.0, *)
final class UsageCardOrderTests: XCTestCase {
    private func card(_ id: String, identity: UsageCardIdentity? = nil) -> UsageGlance {
        UsageGlance(id: id, title: id, value: "Unknown", detail: "Fixture", symbol: "gauge",
            sourceID: id, ordering: identity ?? .source(id))
    }

    func testBeforeAndAfterMovesWorkInBothDirectionsAndRejectInvalidDrops() {
        let cards = [card("a"), card("b"), card("c"), card("d")]
        for from in cards {
            for target in cards where from.id != target.id {
                for placement in [UsageCardPlacement.before, .after] {
                    var order = UsageCardOrder()
                    var expected = cards.map(\.id).filter { $0 != from.id }
                    let index = expected.firstIndex(of: target.id)!
                    expected.insert(from.id, at: index + (placement == .after ? 1 : 0))
                    _ = order.move(from.id, relativeTo: target.id, placement: placement, cards: cards)
                    XCTAssertEqual(order.arranged(cards).map(\.id), expected)
                }
            }
        }
        var order = UsageCardOrder()
        XCTAssertFalse(order.move("missing", relativeTo: "a", placement: .before, cards: cards))
        XCTAssertFalse(order.move("a", relativeTo: "missing", placement: .before, cards: cards))
        XCTAssertFalse(order.move("a", relativeTo: "a", placement: .after, cards: cards))
        XCTAssertTrue(order.keys.isEmpty)
    }

    func testRefreshingStatusAndAmountsDoesNotChangeOrder() {
        let status = card("status-account", identity: .source("account"))
        let other = card("other")
        var order = UsageCardOrder()
        XCTAssertTrue(order.move(other.id, relativeTo: status.id, placement: .before, cards: [status, other]))
        let live = card("account", identity: .source("account"))
        XCTAssertEqual(order.arranged([live, other]).map(\.id), [other.id, live.id])
        XCTAssertEqual(order.arranged([status, other]).map(\.id), [other.id, status.id])
        XCTAssertTrue(order.move(live.id, relativeTo: other.id, placement: .before, cards: [live, other]))
        XCTAssertEqual(order.arranged([other, status]).map(\.id), [status.id, other.id])
    }

    func testQuotaGroupsCarryMemberAccountOrderThroughSplitAndMerge() {
        let first = card("status-first", identity: .source("first"))
        let second = card("status-second", identity: .source("second"))
        let cloud = card("cloud")
        let group = card("quota-provider", identity: .group(sources: ["first", "second"]))
        var order = UsageCardOrder()
        XCTAssertTrue(order.move(cloud.id, relativeTo: first.id, placement: .before, cards: [first, second, cloud]))
        XCTAssertEqual(order.arranged([group, cloud]).map(\.id), [cloud.id, group.id])
        XCTAssertTrue(order.move(group.id, relativeTo: cloud.id, placement: .before, cards: [group, cloud]))
        XCTAssertEqual(order.arranged([cloud, second, first]).map(\.id), [first.id, second.id, cloud.id])
    }

    func testSeparateDrivesKeepTheirOwnPositionsAndInheritMissingDevicePosition() {
        let device = card("status-device", identity: .source("device"))
        let cloud = card("cloud")
        let first = card("drive-first", identity: .drive(sourceID: "device", driveID: "first"))
        let second = card("drive-second", identity: .drive(sourceID: "device", driveID: "second"))
        var order = UsageCardOrder()
        XCTAssertTrue(order.move(device.id, relativeTo: cloud.id, placement: .before, cards: [cloud, device]))
        XCTAssertEqual(order.arranged([cloud, first, second]).map(\.id), [first.id, second.id, cloud.id])
        XCTAssertTrue(order.move(second.id, relativeTo: first.id, placement: .before, cards: [cloud, first, second]))
        XCTAssertEqual(order.arranged([first, cloud, second]).map(\.id), [second.id, first.id, cloud.id])
        XCTAssertEqual(order.arranged([cloud, device]).map(\.id), [device.id, cloud.id])
    }

    func testNewCardsAppendAndTemporarilyAbsentCardsKeepSavedSlots() {
        let a = card("a"), b = card("b"), c = card("c"), d = card("d")
        var order = UsageCardOrder(keys: ["source:a", "source:b", "source:c", "source:b", ""])
        XCTAssertEqual(order.keys.count, 3)
        XCTAssertEqual(order.arranged([d, c, b, a]).map(\.id), ["a", "b", "c", "d"])
        XCTAssertTrue(order.move("c", relativeTo: "a", placement: .before, cards: [a, c]))
        XCTAssertEqual(order.arranged([a, b, c]).map(\.id), ["c", "b", "a"])
        XCTAssertEqual(order.arranged([d, a, c]).map(\.id), ["c", "a", "d"])
    }

    @MainActor
    func testControllerSavesArrangementAcrossRefreshAndRelaunchAndCanReset() async throws {
        let suite = "argus.card-order.tests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(defaults: defaults)
        await store.refresh()
        let controller = UsageController(store: store, defaults: defaults)
        let original = controller.glances.map(\.id)
        let first = try XCTUnwrap(original.first), last = try XCTUnwrap(original.last)
        XCTAssertTrue(controller.moveGlance(last, relativeTo: first, placement: .before))
        let arranged = controller.glances.map(\.id)
        XCTAssertEqual(arranged.first, last)
        XCTAssertFalse(controller.moveGlance(last, by: -1))
        await controller.refresh()
        XCTAssertEqual(controller.glances.map(\.id), arranged)
        let restored = UsageController(store: store, defaults: defaults)
        XCTAssertEqual(restored.glances.map(\.id), arranged)
        XCTAssertTrue(restored.hasCustomCardOrder)
        restored.resetCardOrder()
        XCTAssertFalse(restored.hasCustomCardOrder)
        XCTAssertEqual(restored.glances.map(\.id), original)
        XCTAssertEqual(UsageController(store: store, defaults: defaults).glances.map(\.id), original)
    }
}
