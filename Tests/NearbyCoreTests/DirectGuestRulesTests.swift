import XCTest
@testable import NearbyCore

final class DirectGuestRulesTests: XCTestCase {
    private func ip(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> UInt32 {
        UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
    }

    func testCredsOutsideTheJoinedSubnetIsRefused() {
        let en0 = IPv4Interface(name: "en0", address: ip(192, 168, 137, 5), prefixLength: 24)
        XCTAssertTrue(DirectGuestRules.credsOnLink(joined: en0, host: ip(192, 168, 137, 1)))
        XCTAssertFalse(DirectGuestRules.credsOnLink(joined: en0, host: ip(10, 0, 0, 1)))
        XCTAssertFalse(DirectGuestRules.credsOnLink(joined: en0, host: en0.address))
        XCTAssertFalse(DirectGuestRules.credsOnLink(joined: en0, host: ip(8, 8, 8, 8)))
    }

    func testAnOverlappingSubnetIsRefused() {
        let joined = IPv4Interface(name: "en0", address: ip(192, 168, 49, 2), prefixLength: 24)
        let pdp = IPv4Interface(name: "pdp_ip0", address: ip(192, 168, 49, 30), prefixLength: 24)
        XCTAssertTrue(DirectGuestRules.subnetOverlap(joined: joined, all: [joined, pdp]))
        XCTAssertEqual(DirectGuestRules.credsRefusal(joined: joined, all: [joined, pdp], host: ip(192, 168, 49, 1)), .wifiUnavailable)
        let other = IPv4Interface(name: "en1", address: ip(192, 168, 1, 5), prefixLength: 24)
        XCTAssertFalse(DirectGuestRules.subnetOverlap(joined: joined, all: [joined, other]))
        XCTAssertNil(DirectGuestRules.credsRefusal(joined: joined, all: [joined, other], host: ip(192, 168, 49, 1)))
        let wide = IPv4Interface(name: "en1", address: ip(192, 168, 0, 9), prefixLength: 16)
        XCTAssertTrue(DirectGuestRules.subnetOverlap(joined: joined, all: [joined, wide]))
        XCTAssertEqual(DirectGuestRules.credsRefusal(joined: joined, all: [joined, wide], host: ip(192, 168, 49, 1)), .wifiUnavailable)
    }

    func testTheBandComesFromTheReadingThenTheHost() {
        XCTAssertFalse(DirectGuestRules.bandOk(read: .ghz2_4, hostFreqMhz: 5180))
        XCTAssertTrue(DirectGuestRules.bandOk(read: .unknown, hostFreqMhz: 5180))
        XCTAssertFalse(DirectGuestRules.bandOk(read: .unknown, hostFreqMhz: 0))
        XCTAssertTrue(DirectGuestRules.bandOk(read: .ghz5, hostFreqMhz: 0))
    }

    func testHostVerdictsFollowAndroidsOrder() {
        func verdict(hasKey: Bool = true, guestTuple: Bool = true, status: UInt8 = 1, bearer: UInt8 = 2, validMs: Int = 20000,
                     ticketFresh: Bool = true, attemptRunning: Bool = false, hostsAccepted: Int = 0,
                     sinceLastAttempt: TimeInterval? = nil, foreground: Bool = true, eligible: Bool = true) -> DirectGuestRules.HostVerdict {
            DirectGuestRules.hostVerdict(hasKey: hasKey, guestTuple: guestTuple, status: status, bearer: bearer, validMs: validMs,
                                        ticketFresh: ticketFresh, attemptRunning: attemptRunning, hostsAccepted: hostsAccepted,
                                        sinceLastAttempt: sinceLastAttempt, foreground: foreground, eligible: eligible)
        }
        XCTAssertEqual(verdict(hasKey: false, guestTuple: false, status: 0, bearer: 1, validMs: 0, ticketFresh: false,
                               attemptRunning: true, hostsAccepted: 6, sinceLastAttempt: 1, foreground: false, eligible: false),
                       .decline(.notEligible))
        XCTAssertEqual(verdict(guestTuple: false), .decline(.busy))
        XCTAssertEqual(verdict(status: 0), .ignore)
        XCTAssertEqual(verdict(bearer: 1), .decline(.notEligible))
        XCTAssertEqual(verdict(ticketFresh: false), .decline(.notEligible))
        XCTAssertEqual(verdict(attemptRunning: true), .decline(.busy))
        XCTAssertEqual(verdict(hostsAccepted: 6), .decline(.limit))
        XCTAssertEqual(verdict(sinceLastAttempt: 10), .decline(.limit))
        XCTAssertEqual(verdict(sinceLastAttempt: 30), .accept)
        XCTAssertEqual(verdict(foreground: false), .decline(.notEligible))
        XCTAssertEqual(verdict(eligible: false), .decline(.notEligible))
    }
}
