import XCTest
@testable import NearbyCore

/// B1.2: a value one thread publishes and any thread reads without waiting for the producer.
final class LatestValueTests: XCTestCase {
    func testTheNewestValueWins() {
        let value = LatestValue("first")
        XCTAssertEqual(value.get(), "first")
        value.set("second")
        value.set("third")
        XCTAssertEqual(value.get(), "third")
    }

    func testAReaderNeverWaitsForASlowWriter() {
        let value = LatestValue(0)
        let written = expectation(description: "written")
        DispatchQueue.global(qos: .userInitiated).async {
            // The value is computed for half a second outside `set`, as a route read or an engine call would be.
            Thread.sleep(forTimeInterval: 0.5)
            value.set(42)
            written.fulfill()
        }
        var sawOld = false
        let until = Date().addingTimeInterval(0.4)
        while Date() < until {
            let began = Date()
            let read = value.get()
            XCTAssertLessThan(Date().timeIntervalSince(began), 0.05, "a read waits for the writer")
            if read == 0 { sawOld = true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertTrue(sawOld, "the reader saw the old value while the writer computed")
        wait(for: [written], timeout: 2)
        XCTAssertEqual(value.get(), 42)
    }
}
