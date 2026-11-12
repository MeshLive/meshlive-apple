import XCTest
@testable import NearbyCore

/// The contact sheet's rules (Android ContactActions, ContactClaims, ContactNames, ContactReach).
final class ContactSheetTests: XCTestCase {
    private func fingerprint(_ byte: UInt8) -> IdentityFingerprint {
        IdentityFingerprint(publicKey: try! SoftwareSigningIdentity(rawScalar: Data(repeating: byte, count: 32)).publicKeyEncoded)
    }

    private func book(_ names: [(UInt8, String)]) throws -> VerifiedContactBook {
        let book = VerifiedContactBook()
        for (byte, name) in names {
            let fp = fingerprint(byte)
            try book.markVerified(authenticated: fp, confirmed: fp, name: name, method: "qr")
        }
        return book
    }

    func testTheHintFollowsAndroidsOrder() {
        XCTAssertEqual(ContactReach.hint(recognitionOn: false, holdsLease: false, scannedBothWays: false, meetAvailable: true), .recognisable)
        XCTAssertEqual(ContactReach.hint(recognitionOn: true, holdsLease: true, scannedBothWays: false, meetAvailable: true), .recognisable)
        XCTAssertEqual(ContactReach.hint(recognitionOn: true, holdsLease: false, scannedBothWays: false, meetAvailable: false), .callFromNearby)
        XCTAssertEqual(ContactReach.hint(recognitionOn: true, holdsLease: false, scannedBothWays: false, meetAvailable: true), .askToScan)
        XCTAssertEqual(ContactReach.hint(recognitionOn: true, holdsLease: false, scannedBothWays: true, meetAvailable: true), .scanAgain)
    }

    func testRenameRefusesBlankInvalidTakenAndUnknown() throws {
        let book = try book([(7, "Asha"), (9, "Ravi")])
        let ravi = fingerprint(9).hex
        XCTAssertEqual(ContactNames.renameDecision("  ", fingerprintHex: ravi, contacts: book.contacts), .empty)
        XCTAssertEqual(ContactNames.renameDecision("ASHA", fingerprintHex: ravi, contacts: book.contacts), .nameTaken, "reads the same as Asha")
        XCTAssertEqual(ContactNames.renameDecision(String(repeating: "a", count: 40), fingerprintHex: ravi, contacts: book.contacts), .invalidName)
        XCTAssertEqual(ContactNames.renameDecision("Ravi K", fingerprintHex: fingerprint(5).hex, contacts: book.contacts), .notFound)
        guard case .renamed = ContactNames.renameDecision("Ravi K", fingerprintHex: ravi, contacts: book.contacts) else {
            return XCTFail("a new name is accepted")
        }
        XCTAssertEqual(ContactNames.renameDecision("Ravi", fingerprintHex: ravi, contacts: book.contacts), .renamed("Ravi"), "its own name is not taken")
    }

    func testTheFirstClaimIsSeenAndALaterOneWaitsForTheUser() throws {
        let book = try book([(9, "Ravi")])
        let ravi = fingerprint(9).hex
        XCTAssertTrue(book.recordClaim(fingerprintHex: ravi, name: "Ravi"))
        XCTAssertFalse(book.contacts[0].claimPending, "the first name needs no answer")
        XCTAssertFalse(book.recordClaim(fingerprintHex: ravi, name: "Ravi"), "unchanged")
        XCTAssertTrue(book.recordClaim(fingerprintHex: ravi, name: "Ravi Kumar"))
        XCTAssertTrue(book.contacts[0].claimPending)
        XCTAssertEqual(book.contacts[0].displayName, "Ravi", "a claim never renames")
        XCTAssertTrue(book.acknowledgeClaim(fingerprintHex: ravi))
        XCTAssertFalse(book.contacts[0].claimPending)
        XCTAssertFalse(book.acknowledgeClaim(fingerprintHex: ravi), "nothing left to acknowledge")
    }

    func testAClaimIsKeptOnlyForAContactAndOnlyAsAValidName() throws {
        let book = try book([(9, "Ravi")])
        XCTAssertFalse(book.recordClaim(fingerprintHex: fingerprint(5).hex, name: "Stranger"), "not a contact")
        XCTAssertFalse(book.recordClaim(fingerprintHex: fingerprint(9).hex, name: "~Ravi"), "the claim mark is not a name")
        XCTAssertNil(book.contacts[0].claimedName)
    }

    func testVerifyingAgainKeepsTheClaimAndTheMutualScan() throws {
        let book = try book([(9, "Ravi")])
        let fp = fingerprint(9)
        book.recordClaim(fingerprintHex: fp.hex, name: "Ravi")
        book.recordClaim(fingerprintHex: fp.hex, name: "Ravi Kumar")
        book.markScannedBothWays(fingerprintHex: fp.hex)
        try book.markVerified(authenticated: fp, confirmed: fp, name: "Ravi", method: "qr")
        XCTAssertEqual(book.contacts[0].claimedName, "Ravi Kumar")
        XCTAssertTrue(book.contacts[0].claimPending)
        XCTAssertNotNil(book.contacts[0].scannedBothWaysAt)
    }

    func testSaveContactAsNeverOffersAnIDAndPrefersYourOwnName() throws {
        let fp = fingerprint(9)
        let handle = IdentityHandle.handle(prefix: fp.nodeId.prefix) ?? ""
        let unnamed = VerifiedContact(fingerprint: fp, displayName: handle, method: "qr")
        let named = VerifiedContact(fingerprint: fp, displayName: "Mum", method: "qr")
        XCTAssertEqual(ContactNames.suggestion(saved: named, shared: "Sunita"), "Mum")
        XCTAssertEqual(ContactNames.suggestion(saved: unnamed, shared: "Sunita"), "Sunita")
        XCTAssertEqual(ContactNames.suggestion(saved: unnamed, shared: nil), "")
        XCTAssertEqual(ContactNames.suggestion(saved: unnamed, shared: handle), "", "a handle is never a name")
    }

    func testNamedContactsComeFirstAlphabetically() throws {
        let unnamedFp = fingerprint(3)
        let unnamed = VerifiedContact(fingerprint: unnamedFp, displayName: IdentityHandle.handle(prefix: unnamedFp.nodeId.prefix) ?? "", method: "qr")
        let list = [unnamed, VerifiedContact(fingerprint: fingerprint(9), displayName: "ravi", method: "qr"),
                    VerifiedContact(fingerprint: fingerprint(7), displayName: "Asha", method: "qr")]
        XCTAssertEqual(ContactNames.sorted(list).map(\.fingerprintHex), [fingerprint(7).hex, fingerprint(9).hex, unnamedFp.hex])
    }

    func testARecordSavedBeforeClaimsStillOpens() throws {
        let fp = fingerprint(9)
        let json = "[{\"fingerprintHex\":\"\(fp.hex)\",\"displayName\":\"Ravi\",\"method\":\"qr\",\"verifiedAt\":0}]"
        let list = try JSONDecoder().decode([VerifiedContact].self, from: Data(json.utf8))
        XCTAssertNil(list[0].claimedName)
        XCTAssertFalse(list[0].claimPending)
    }
}
