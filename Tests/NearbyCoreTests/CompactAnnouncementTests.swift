import XCTest
@testable import NearbyCore

/// Normative vectors of Interop/ANDROID_DISCOVERY_ADDENDUM.md section A (iPhone compact announcement UUID).
final class CompactAnnouncementTests: XCTestCase {
    private let p1 = Data([1, 2, 3, 4, 5, 6])
    private let p2 = Data([0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6])
    private typealias A = DiscoveryAnnouncement

    func testVectorTable() throws {
        let call = A(nodeIdPrefix: p1, flags: A.flagAcceptingConnections | A.flagPrivateCallAvailable, capabilitySummary: 3, streamToken: 0, routeCost: 0)
        XCTAssertEqual(try CompactAnnouncement.encode(call), "C8D64010-2030-4050-60C0-000000000000")
        let relayedCall = A(nodeIdPrefix: p2, flags: A.flagAcceptingConnections | A.flagPrivateCallAvailable | A.flagGattTransport, capabilitySummary: 1, streamToken: 0, routeCost: 2)
        XCTAssertEqual(try CompactAnnouncement.encode(relayedCall), "C8D64A1B-2C3D-4E5F-6848-000000000000")
        let viewer = A(nodeIdPrefix: p1, flags: A.flagAcceptingConnections, capabilitySummary: 3, streamToken: 0x9abcdef0, routeCost: 0, streamBitrateKbps: 300)
        XCTAssertEqual(try CompactAnnouncement.encode(viewer), "C8D65010-2030-4050-60C0-D5E6F780C000")
        let offer = A(nodeIdPrefix: p2, flags: A.flagStreamAvailable | A.flagGattTransport | A.flagRelayCapable | A.flagStreamPaused, capabilitySummary: 1,
                      streamToken: 0xdeadbeef, routeCost: 1, sequence: 0x85, streamWidth: 640, streamHeight: 360, streamFps: 15, streamBitrateKbps: 300)
        XCTAssertEqual(try CompactAnnouncement.encode(offer), "C8D66A1B-2C3D-4E5F-6E46-F56DF77C2A0C")
        for a in [call, relayedCall, viewer, offer] {
            XCTAssertEqual(CompactAnnouncement.decode(try CompactAnnouncement.encode(a)), a)
        }
        // Lowercase input decodes too; Android's 22-byte codec round-trips the decoded value.
        let decoded = try XCTUnwrap(CompactAnnouncement.decode("c8d66a1b-2c3d-4e5f-6e46-f56df77c2a0c"))
        XCTAssertEqual(try DiscoveryAnnouncement(decoding: try decoded.encoded()), offer)
        XCTAssertTrue(decoded.isFullStreamOffer)
    }

    func testRejectsForeignAndReservedValues() throws {
        XCTAssertNil(CompactAnnouncement.decode("C8D5A101-9F88-4F65-A03D-7F5A2FB921FA")) // Android control service
        XCTAssertNil(CompactAnnouncement.decode("C8D68010-2030-4050-60C0-000000000000")) // version 2
        XCTAssertNil(CompactAnnouncement.decode("C8D67010-2030-4050-60C0-000000000000")) // kind 3
        XCTAssertNil(CompactAnnouncement.decode("C8D64010-2030-4050-60C0-000000000001")) // call reserved bit
        XCTAssertNil(CompactAnnouncement.decode("C8D64010-2030-4050-62C0-000000000000")) // call marked paused
        XCTAssertNil(CompactAnnouncement.decode("C8D65010-2030-4050-60C0-D5E6F780C001")) // viewer reserved bit
        XCTAssertNil(CompactAnnouncement.decode("not-a-uuid"))
        let tooFar = A(nodeIdPrefix: p1, flags: A.flagAcceptingConnections | A.flagPrivateCallAvailable, capabilitySummary: 1, streamToken: 0, routeCost: 16)
        XCTAssertThrowsError(try CompactAnnouncement.encode(tooFar))
        let classic = A(nodeIdPrefix: p1, flags: A.flagStreamAvailable | A.flagClassicTransport, capabilitySummary: 1, streamToken: 0x80000001, routeCost: 0)
        XCTAssertThrowsError(try CompactAnnouncement.encode(classic))
        let recovery = A(nodeIdPrefix: p1, flags: A.flagAcceptingConnections | A.flagRouteRecovery, capabilitySummary: 1, streamToken: 0x80000001, routeCost: 0, recoveryFromNodeIdPrefix: p2)
        XCTAssertThrowsError(try CompactAnnouncement.encode(recovery))
        let lowToken = A(nodeIdPrefix: p1, flags: A.flagAcceptingConnections, capabilitySummary: 1, streamToken: 5, routeCost: 0)
        XCTAssertThrowsError(try CompactAnnouncement.encode(lowToken))
    }

    /// Review R1/R2/R4 additions.
    func testReviewedRejectListAndQuantization() throws {
        func flip(_ uuid: String, bit: Int) -> String {
            var b = UUID(uuidString: uuid)!.rawBytes
            let byte = 15 - bit / 8; b[byte] ^= UInt8(1 << (bit % 8))
            return UUID(rawBytes: b).uuidString
        }
        let v1 = "C8D64010-2030-4050-60C0-000000000000", v3 = "C8D65010-2030-4050-60C0-D5E6F780C000", v4 = "C8D66A1B-2C3D-4E5F-6E46-F56DF77C2A0C"
        // R1: vector 4 with the H.264 bit (56) set decodes with capability 0x05.
        XCTAssertEqual(CompactAnnouncement.decode(flip(v4, bit: 56))?.capabilitySummary, 0x05)
        // R2: call offer bits 49..0, viewer bits 11..0, paused outside stream offers, versions 0/2/3 and kind 3 reject.
        XCTAssertNil(CompactAnnouncement.decode(flip(v1, bit: 19))); XCTAssertNil(CompactAnnouncement.decode(flip(v1, bit: 0)))
        XCTAssertNil(CompactAnnouncement.decode(flip(v1, bit: 49)))
        for bit in 0...11 { XCTAssertNil(CompactAnnouncement.decode(flip(v3, bit: bit)), "viewer bit \(bit)") }
        XCTAssertNotNil(CompactAnnouncement.decode(flip(v3, bit: 12)))
        XCTAssertNil(CompactAnnouncement.decode(flip(v1, bit: 57))); XCTAssertNil(CompactAnnouncement.decode(flip(v3, bit: 57)))
        XCTAssertNotNil(CompactAnnouncement.decode(flip(v4, bit: 57)))
        for (versionBits, valid) in [(0, false), (1, true), (2, false), (3, false)] {
            var b = UUID(uuidString: v1)!.rawBytes; b[2] = (b[2] & 0x3f) | UInt8(versionBits << 6)
            XCTAssertEqual(CompactAnnouncement.decode(UUID(rawBytes: b).uuidString) != nil, valid, "version \(versionBits)")
        }
        var kind3 = UUID(uuidString: v1)!.rawBytes; kind3[2] |= 0x30
        XCTAssertNil(CompactAnnouncement.decode(UUID(rawBytes: kind3).uuidString))
        // Route cost uses its 4 bits fully (15 is valid).
        XCTAssertEqual(CompactAnnouncement.decode("C8D64010-2030-4050-60FC-000000000000")?.routeCost, 15)
        // R4: 310 kbps viewer -> 300; 5000 kbps stream -> 3175.
        let viewer = A(nodeIdPrefix: p1, flags: A.flagAcceptingConnections, capabilitySummary: 3, streamToken: 0x9abcdef0, routeCost: 0, streamBitrateKbps: 310)
        XCTAssertEqual(CompactAnnouncement.decode(try CompactAnnouncement.encode(viewer))?.streamBitrateKbps, 300)
        // R1: an encoder keeps bit 56 at 0 while H.264 is not negotiated.
        let h264 = A(nodeIdPrefix: p1, flags: A.flagStreamAvailable, capabilitySummary: 0x05, streamToken: 0x80000002, routeCost: 0)
        XCTAssertEqual(CompactAnnouncement.decode(try CompactAnnouncement.encode(h264))?.capabilitySummary, 0x01)
    }

    func testQuantizationIsExplicit() throws {
        let odd = A(nodeIdPrefix: p1, flags: A.flagStreamAvailable, capabilitySummary: 2, streamToken: 0x80000002, routeCost: 0,
                    streamWidth: 1280, streamHeight: 720, streamFps: 60, streamBitrateKbps: 5000)
        let decoded = try XCTUnwrap(CompactAnnouncement.decode(try CompactAnnouncement.encode(odd)))
        XCTAssertEqual(decoded.streamWidth, 0); XCTAssertEqual(decoded.streamFps, 0)
        XCTAssertEqual(decoded.streamBitrateKbps, 3175)
        XCTAssertEqual(decoded.capabilitySummary, NodeCapabilities.codecAV1)
    }
}
