import Foundation
import XCTest
@testable import UniversalTmuxMac

final class BrokerInputTests: XCTestCase {
    func testLargeInputIsSplitBelowLegacyBrokerLimitAndRoundTripsExactly() throws {
        let pane = "%42"
        let payload = (0..<(128 * 1024 + 137)).map { UInt8($0 % 251) }
        let frames = BrokerWireFrames.encode(op: Op.input, pane: pane, payload: payload)

        XCTAssertGreaterThan(frames.count, 1)
        var reconstructed: [UInt8] = []
        for frame in frames {
            let bytes = [UInt8](frame)
            XCTAssertEqual(bytes[0], Op.input)
            let paneLength = Int(bytes[1])
            XCTAssertEqual(String(decoding: bytes[2..<(2 + paneLength)], as: UTF8.self), pane)
            let chunk = bytes[(2 + paneLength)...]
            XCTAssertLessThanOrEqual(chunk.count, BrokerWireFrames.maxInputPayloadBytes)
            XCTAssertLessThan(frame.count, 32 * 1024)
            reconstructed.append(contentsOf: chunk)
        }

        XCTAssertEqual(reconstructed, payload)
    }

    func testOutboundQueuePreservesBracketedPasteOrder() {
        let queue = BrokerOutboundQueue()
        queue.activate(generation: 7)
        let expected = [Data([0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]),
                        Data(repeating: 0x61, count: 4096),
                        Data(repeating: 0x62, count: 17),
                        Data([0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e])]
        let completed = expectation(description: "all frames sent")
        completed.expectedFulfillmentCount = expected.count
        let lock = NSLock()
        var sent: [Data] = []

        for frame in expected {
            queue.enqueue(
                [frame],
                generation: 7,
                sender: { data, completion in
                    lock.lock()
                    sent.append(data)
                    lock.unlock()
                    completed.fulfill()
                    completion(nil)
                },
                onFailure: { error in
                    XCTFail("unexpected send failure: \(error)")
                }
            )
        }

        wait(for: [completed], timeout: 2)
        lock.lock()
        let result = sent
        lock.unlock()
        XCTAssertEqual(result, expected)
    }

    func testOutboundQueueNeverReplaysRetiredSocketFrames() {
        let queue = BrokerOutboundQueue()
        queue.activate(generation: 1)
        let firstStarted = expectation(description: "old socket started")
        let callbackLock = NSLock()
        var finishOld: ((Error?) -> Void)?
        queue.enqueue(
            [Data([1]), Data([2])],
            generation: 1,
            sender: { _, completion in
                callbackLock.lock()
                finishOld = completion
                callbackLock.unlock()
                firstStarted.fulfill()
            },
            onFailure: { _ in XCTFail("retired failure must be ignored") }
        )
        wait(for: [firstStarted], timeout: 2)

        queue.deactivate()
        queue.activate(generation: 2)
        let newSent = expectation(description: "new socket sent")
        let valuesLock = NSLock()
        var values: [UInt8] = []
        queue.enqueue(
            [Data([3])],
            generation: 2,
            sender: { data, completion in
                valuesLock.lock()
                values.append(data[0])
                valuesLock.unlock()
                newSent.fulfill()
                completion(nil)
            },
            onFailure: { error in XCTFail("unexpected send failure: \(error)") }
        )
        callbackLock.lock()
        let oldCompletion = finishOld
        callbackLock.unlock()
        oldCompletion?(nil)

        wait(for: [newSent], timeout: 2)
        valuesLock.lock()
        let result = values
        valuesLock.unlock()
        XCTAssertEqual(result, [3])
    }
}
