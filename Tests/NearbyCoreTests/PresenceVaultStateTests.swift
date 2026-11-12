import XCTest
@testable import NearbyCore

/// The presence-vault rules behind "Can see when I'm nearby", "Reset presence key", Forget and a fresh install.
final class PresenceVaultStateTests: XCTestCase {
    let epoch: Int64 = 1_990_656
    private func delivered(_ state: inout PresenceVaultState, _ peer: String) {
        var record = state.contacts[peer] ?? .init(); record.deliveredGeneration = state.generation; state.contacts[peer] = record
    }

    /// Decision 2026-11-06 (all platforms): "Can see when I'm nearby" starts as not yet asked, which counts as off
    /// until the user answers; a no is kept as an answer; off after a delivery revokes.
    func testTheSwitchStartsNotYetAskedCountsAsOffAndRevokesOnlyADeliveredLease() {
        var state = PresenceVaultState(); state.dayKeys = DayKeyWindow.fresh(epoch: epoch)
        XCTAssertFalse(state.canSeeMe("aa"), "not yet asked counts as off")
        XCTAssertNil(state.answer("aa"))
        state.contacts["bb"] = .init()
        XCTAssertFalse(state.canSeeMe("bb"), "a record made for a received lease or a delivery is not an answer")
        XCTAssertFalse(state.setCanSeeMe("aa", false, epoch: epoch), "off before any delivery changes nothing on the wire")
        XCTAssertEqual(state.generation, 1)
        XCTAssertEqual(state.answer("aa"), false, "a no is kept as an answer")
        XCTAssertFalse(state.canSeeMe("aa"))
        state.setCanSeeMe("aa", true, epoch: epoch)
        XCTAssertTrue(state.canSeeMe("aa"), "a yes makes the contact able to see this phone")
        delivered(&state, "aa")
        let oldKeys = state.dayKeys
        XCTAssertTrue(state.setCanSeeMe("aa", false, epoch: epoch), "off after delivery revokes")
        XCTAssertEqual(state.generation, 2)
        XCTAssertTrue(state.dayKeys.values.allSatisfy { !oldKeys.values.contains($0) }, "a whole new window")
        XCTAssertFalse(state.holdsCurrentLease("aa"))
    }

    func testResetForgetAndFreshInstall() {
        var state = PresenceVaultState(); state.dayKeys = DayKeyWindow.fresh(epoch: epoch)
        delivered(&state, "aa"); state.contacts["bb"] = .init()
        state.newGeneration(epoch: epoch)                         // Reset presence key
        XCTAssertEqual(state.generation, 2); XCTAssertFalse(state.holdsCurrentLease("aa"))
        XCTAssertFalse(state.forget("bb", epoch: epoch), "forgetting a contact without a current lease starts nothing")
        delivered(&state, "aa")
        XCTAssertTrue(state.forget("aa", epoch: epoch)); XCTAssertEqual(state.generation, 3); XCTAssertNil(state.contacts["aa"])
        state.contacts["cc"] = .init(); delivered(&state, "cc")
        state.freshInstall(epoch: epoch)
        XCTAssertTrue(state.contacts.isEmpty); XCTAssertEqual(state.generation, 4)
        let data = try! JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(PresenceVaultState.self, from: data), state, "the Keychain form round-trips")
    }

    /// Stored answers (a yes or a no, also as older builds wrote them) keep their value; a contact without one stays not
    /// yet asked.
    func testStoredAnswersRoundTripAndAMissingAnswerStaysNotYetAsked() throws {
        var state = PresenceVaultState()
        state.contacts["yes"] = .init(); state.contacts["yes"]?.canSeeMe = true
        state.contacts["no"] = .init(); state.contacts["no"]?.canSeeMe = false
        state.contacts["unasked"] = .init()
        let decoded = try JSONDecoder().decode(PresenceVaultState.self, from: try JSONEncoder().encode(state))
        XCTAssertEqual(decoded.answer("yes"), true)
        XCTAssertTrue(decoded.canSeeMe("yes"))
        XCTAssertEqual(decoded.answer("no"), false)
        XCTAssertNil(decoded.answer("unasked"))
        XCTAssertFalse(decoded.canSeeMe("unasked"))
    }
}
