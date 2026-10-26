import XCTest
import NearbyCore
@testable import DesktopSupport

final class DesktopNearbyNamesTests: XCTestCase {
    private func offer(_ hex: String, rotating: Bool = true) -> DiscoveryAnnouncement {
        var offer = DiscoveryAnnouncement(nodeIdPrefix: Data(hex: hex)!,
                                          flags: DiscoveryAnnouncement.flagPrivateCallAvailable | DiscoveryAnnouncement.flagAcceptingConnections,
                                          capabilitySummary: 1, streamToken: 0, routeCost: 0)
        offer.rotating = rotating
        return offer
    }

    func testBundledAndroidVectorsMatchIncludingDisambiguators() throws {
        let names = try XCTUnwrap(DesktopNearbyNames.shared)
        let first = try XCTUnwrap(names.name(for: offer("44e69c0a7a7d")))
        XCTAssertEqual(first.text, "mild bream")
        XCTAssertEqual(first.numbered, "mild bream 19")
        XCTAssertEqual(first.chip, 6)
        XCTAssertEqual(first.idTail, "7a7d")
        let next = try XCTUnwrap(names.name(for: offer("67aba670e65a")))
        XCTAssertEqual(next.text, "amiable otter")
        XCTAssertEqual(next.number, 35)
        XCTAssertEqual(next.chip, 5)
    }

    func testBlockedPairUsesAndroidCounterRehash() throws {
        let name = try XCTUnwrap(DesktopNearbyNames.shared?.name(for: offer("1020000006b8")))
        XCTAssertEqual(name.text, "plum otter")
        XCTAssertEqual(name.number, 83)
        XCTAssertEqual(name.chip, 2)
    }

    func testStableAndMalformedAdvertisementsNeverBecomeGeneratedNames() throws {
        let names = try XCTUnwrap(DesktopNearbyNames.shared)
        XCTAssertNil(names.name(for: offer("44e69c0a7a7d", rotating: false)))
        var malformed = offer("44e69c0a7a7d")
        malformed.nodeIdPrefix = Data(repeating: 1, count: 16)
        XCTAssertNil(names.name(for: malformed))
    }

    func testCollisionsDisambiguateEveryRowWithoutMergingOrDependingOnOrder() {
        let a = Data([1]), b = Data([2]), c = Data([3]), d = Data([4])
        let rows: [Data: DesktopNearbyNames.Name] = [
            a: .init(text: "mild bream", number: 19, idTail: "0011", chip: 0),
            b: .init(text: "mild bream", number: 19, idTail: "0022", chip: 0),
            c: .init(text: "mild bream", number: 35, idTail: "0033", chip: 0),
            d: .init(text: "amiable otter", number: 10, idTail: "0044", chip: 0)
        ]
        let expected = [a: "mild bream 19-0011", b: "mild bream 19-0022", c: "mild bream 35", d: "amiable otter"]
        XCTAssertEqual(DesktopNearbyNames.labels(rows), expected)
        XCTAssertEqual(DesktopNearbyNames.labels(Dictionary(uniqueKeysWithValues: rows.reversed())), expected)
        XCTAssertEqual(DesktopNearbyNames.labels([a: rows[a]!]), [a: "mild bream"])
    }

    func testEditedNameDataIsRefusedInsteadOfChangingEveryPeersName() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Desktop/Support/Names")
        let a = try Data(contentsOf: root.appendingPathComponent("adjectives-v2.txt"))
        let n = try Data(contentsOf: root.appendingPathComponent("nouns-v2.txt"))
        let b = try Data(contentsOf: root.appendingPathComponent("blocked-pairs-v2.txt"))
        XCTAssertNotNil(DesktopNearbyNames(adjectives: a, nouns: n, blockedPairs: b))
        XCTAssertNil(DesktopNearbyNames(adjectives: a + Data([0]), nouns: n, blockedPairs: b))
        XCTAssertNil(DesktopNearbyNames(adjectives: a, nouns: n, blockedPairs: b.dropLast()))
    }
}
