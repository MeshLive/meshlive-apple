import XCTest
import AVFoundation
@testable import NearbyCore

final class CoreUtilityTests: XCTestCase {
    func testRealResamplingPreservesToneAndDuration() throws {
        let from = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let to = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let converter = try PCMResampler(input: from, output: to)
        let input = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: 1024)!
        var received: [Float] = []; var offset = 0
        while offset < 88_200 {
            let count = min(1024, 88_200 - offset); input.frameLength = UInt32(count)
            for i in 0..<count { input.floatChannelData![0][i] = Float(sin(Double(offset + i) * 2 * .pi * 440 / 44_100)) }
            received.append(contentsOf: try converter.convert(input)); offset += count
        }
        received.append(contentsOf: try converter.convert(nil, ending: true))
        XCTAssertEqual(received.count, 16_000, accuracy: 24)
        // Rate relabeling would produce about 88,200 samples and an 80 Hz tone, failing both checks.
        let steady = Array(received.dropFirst(80).dropLast(80))
        var rising = 0
        for i in 1..<steady.count { if steady[i - 1] <= 0 && steady[i] > 0 { rising += 1 } }
        let frequency = Double(rising) * 8000 / Double(steady.count)
        XCTAssertEqual(frequency, 440, accuracy: 2)
        let power = steady.reduce(0.0) { $0 + Double($1 * $1) } / Double(steady.count)
        XCTAssertGreaterThan(power, 0.4); XCTAssertLessThan(power, 0.6)
        converter.reset(); input.frameLength = 1024
        input.floatChannelData![0].initialize(repeating: 0, count: 1024)
        let afterInterruption = try converter.convert(input) + converter.convert(nil, ending: true)
        XCTAssertTrue(afterInterruption.allSatisfy { abs($0) < 0.00001 })
    }
    func testBoundedHandoffAdmissionAndCancellation() {
        let mailbox = BoundedMailbox<Int>(capacity: 3)
        XCTAssertEqual(mailbox.offer(1), true); XCTAssertEqual(mailbox.offer(2), false); XCTAssertEqual(mailbox.offer(3), false)
        XCTAssertNil(mailbox.offer(4)); XCTAssertEqual(mailbox.takeAll(), [1,2,3]); XCTAssertTrue(mailbox.takeAll().isEmpty)
        XCTAssertEqual(mailbox.offer(5), true); XCTAssertEqual(mailbox.takeAll(), [5])
        XCTAssertEqual(mailbox.offerLatest(6), true); XCTAssertEqual(mailbox.offerLatest(7), false)
        XCTAssertEqual(mailbox.takeAll(), [7])
    }

    /// A call's setup stages: a repeated stage keeps its first time, and the largest step names the slowest wait.
    func testCallSetupTimelineNamesTheSlowestStage() {
        var t = CallSetupTimeline(origin: 100)
        XCTAssertEqual(t.mark("tap", at: 100)?.ms, 0)
        XCTAssertEqual(t.mark("services", at: 100.4)?.stepMs, 400)
        XCTAssertEqual(t.mark("link_auth", at: 101.9)?.stepMs, 1_500)
        XCTAssertNil(t.mark("services", at: 102), "a retry's stage keeps the first time")
        t.mark("first_frame", at: 102.2)
        XCTAssertEqual(t.summary, "tap:0 services:400 link_auth:1900 first_frame:2200")
        XCTAssertEqual(t.largestStep?.name, "link_auth"); XCTAssertEqual(t.largestStep?.ms, 1_500)
        XCTAssertEqual(t.totalMs, 2_200)
    }
}
