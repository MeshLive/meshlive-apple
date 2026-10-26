import XCTest
@testable import NearbyCore

/// Android AudioLiveRelayTest and AudioLiveRelayGuardTest vectors.
final class AudioLiveRelayPolicyTests: XCTestCase {
    func testAuthenticatedPresetAdmissionIgnoresRoundedAdvertRate() {
        XCTAssertEqual(AudioLiveRelayAdmission.perLinkKbps(preset: 2), 41.424, accuracy: 0.001)
        for (budget, preset, fits) in [(83.0, UInt8(2), true), (65, 2, false), (65, 1, true), (60, 1, false), (130, 3, false), (430, 3, true)] {
            XCTAssertEqual(LinkCapacityPolicy.relayFits(budgetKbps: budget, perLinkKbps: AudioLiveRelayAdmission.perLinkKbps(preset: preset)), fits)
        }
        let learned = LearnedLinkCapacity(ceilingKbps: 72, ceilingMeasuredAtMs: 1)
        XCTAssertFalse(RelayAdmission.evaluate(learned: learned, advertisedKbps: 0, fps: 0, nowMs: 1, audioPreset: 2).fits)
        XCTAssertTrue(RelayAdmission.evaluate(learned: learned, advertisedKbps: 0, fps: 0, nowMs: 1, audioPreset: 1).fits)
    }
    private func warmed() -> AudioLiveRelayInboundGuard {
        let g = AudioLiveRelayInboundGuard(nominalKbps: 24)
        for step in 0..<100 { g.onBytes(475, now: Double(step) * 0.2) }
        g.onChildCount(1, now: 20)
        XCTAssertEqual(g.baselineKbps, 19, accuracy: 0.01)
        return g
    }
    func testParentCollapseWithdrawsAfterGraceAndSustainedWindow() {
        let g = warmed()
        var first: Double?
        for step in 0..<40 {
            let now = 20 + Double(step) * 0.2
            g.onBytes(200, now: now)
            if g.shouldDropChild(now: now), first == nil { first = now - 20 }
        }
        XCTAssertNotNil(first)
        XCTAssertTrue((3.5...6.5).contains(first ?? 0))
        g.onChildCount(0, now: 28)
        XCTAssertFalse(g.shouldDropChild(now: 100))
    }
    func testTransientMildLossAndPauseKeepChild() {
        for rate in [19.0, 15.5] {
            let g = warmed()
            for step in 0..<350 {
                let now = 20 + Double(step) * 0.2
                g.onBytes(Int((step < 8 ? 13 : rate) * 25), now: now)
                XCTAssertFalse(g.shouldDropChild(now: now))
            }
            XCTAssertTrue(g.childCarriedHealthily(now: 90))
            g.onPausedChanged(true, now: 90)
            XCTAssertFalse(g.shouldDropChild(now: 190))
            g.onPausedChanged(false, now: 190)
            for step in 0..<30 {
                let now = 190 + Double(step) * 0.2
                g.onBytes(475, now: now)
                XCTAssertFalse(g.shouldDropChild(now: now))
            }
        }
        let fresh = AudioLiveRelayInboundGuard(nominalKbps: 24)
        fresh.onChildCount(1, now: 0)
        XCTAssertEqual(fresh.baselineKbps, 18)
    }
    func testTransportCooldownDoublesAndHealthyResetsNextFailure() {
        let m = AudioLiveRelayMemory()
        for expected in [120.0, 240, 480, 960, 960] {
            XCTAssertEqual(m.onDropped(.gatt, now: 10), expected)
            XCTAssertEqual(m.blockedFor(.gatt, now: 11), expected - 1)
            XCTAssertEqual(m.blockedFor(.l2cap, now: 11), 0)
        }
        m.onHealthy(.gatt)
        XCTAssertEqual(m.blockedFor(.gatt, now: 11), 959)
        XCTAssertEqual(m.onDropped(.gatt, now: 1000), 120)
        m.reset()
        XCTAssertEqual(m.blockedFor(.gatt, now: 1001), 0)
    }
}
