import XCTest
@testable import NearbyCore

/// B1F step 2: a retired decoder is invalidated on its own serial queue, after the in-flight decode, and a queued key
/// frame that has not started yet sees the retired flag and never touches the decoder.
final class DecoderRetirementTests: XCTestCase {
    func testInvalidateRunsAfterTheInFlightDecodeAndQueuedKeyFramesAreSkipped() {
        let queue = DispatchQueue(label: "test.decoder.retirement")
        let retirement = DecoderRetirement()
        let lock = NSLock()
        var events: [String] = []
        func record(_ event: String) { lock.withLock { events.append(event) } }

        let started = expectation(description: "decode started")
        queue.async {
            guard !retirement.isRetired else { return }
            record("decode-start")
            started.fulfill()
            Thread.sleep(forTimeInterval: 0.1)
            record("decode-end")
        }
        wait(for: [started], timeout: 2)

        retirement.retire()
        let finished = expectation(description: "invalidate finished")
        queue.async {
            guard !retirement.isRetired else { return }
            record("queued-key-frame")
        }
        queue.async {
            record("invalidate")
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)

        XCTAssertEqual(events, ["decode-start", "decode-end", "invalidate"])
    }
}
