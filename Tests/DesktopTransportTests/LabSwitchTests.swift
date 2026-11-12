import XCTest
@testable import MeshPeer

/// Promoted switches (2026-11-04: rotating discovery IDs, hidden identities, pseudonyms, generated names): a value
/// the old Settings row stored never turns the protection off; only a DEBUG launch argument does.
final class LabSwitchTests: XCTestCase {
    func testNothingStoredGivesTheShippedValue() {
        XCTAssertTrue(LabSwitch.promoted("labSwitchTestsUnset", shipped: true))
        XCTAssertFalse(LabSwitch.promoted("labSwitchTestsUnset", shipped: false))
    }

    func testAStoredOffFromTheOldSettingsRowIsIgnored() {
        let key = "labSwitchTestsStoredOff"
        UserDefaults.standard.set(false, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        XCTAssertFalse(LabSwitch.read(key, shipped: true, in: .standard), "an ordinary lab switch reads the stored off")
        XCTAssertTrue(LabSwitch.promoted(key, shipped: true), "a promoted switch ignores it")
    }

    func testALaunchArgumentStillTurnsItOffOrOn() {
        XCTAssertFalse(LabSwitch.promoted("experimentalBmh3", shipped: true, arguments: ["experimentalBmh3": "NO"]))
        XCTAssertFalse(LabSwitch.promoted("experimentalBmh3", shipped: true, arguments: ["experimentalBmh3": "0"]))
        XCTAssertTrue(LabSwitch.promoted("experimentalDesktopAndroidCompatibility", shipped: false,
                                         arguments: ["experimentalDesktopAndroidCompatibility": "YES"]))
        XCTAssertTrue(LabSwitch.promoted("experimentalRotatingIds", shipped: true, arguments: ["experimentalBmh3": "NO"]),
                      "another switch's argument changes nothing")
    }

    func testPlaybackGainFromTheLaunchArgumentAppliesOnlyInDebugBuilds() {
        func gain(_ args: [String], debug: Bool = true) -> Float { LabSwitch.playbackGain(arguments: args, debugBuild: debug) }
        XCTAssertEqual(gain(["app", "-NearbyPlaybackGain", "0.01"]), 0.01)
        XCTAssertEqual(gain(["app", "-NearbyPlaybackGain", "0.01"], debug: false), 1, "a release build ignores it")
        XCTAssertEqual(gain(["app"]), 1, "no argument plays at full volume")
        XCTAssertEqual(gain(["app", "-NearbyPlaybackGain"]), 1, "a missing value is ignored")
        XCTAssertEqual(gain(["app", "-NearbyPlaybackGain", "loud"]), 1)
        XCTAssertEqual(gain(["app", "-NearbyPlaybackGain", "nan"]), 1)
        XCTAssertEqual(gain(["app", "-NearbyPlaybackGain", "5"]), 1, "clamped to 1")
        XCTAssertEqual(gain(["app", "-NearbyPlaybackGain", "-2"]), 0, "clamped to 0")
    }

    func testAStoredWriteBurstAppliesOnlyInDebugBuilds() throws {
        let suite = "LabSwitchTests.gattWriteBurst"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        store.removePersistentDomain(forName: suite)
        defer { store.removePersistentDomain(forName: suite) }
        XCTAssertEqual(GattLinkSettings.storedWriteBurst(in: store, debugBuild: true), 0, "off when nothing is stored")
        store.set(4, forKey: "gattWriteBurst")
        XCTAssertEqual(GattLinkSettings.storedWriteBurst(in: store, debugBuild: true), 4, "a DEBUG build reads the lab value")
        XCTAssertEqual(GattLinkSettings.storedWriteBurst(in: store, debugBuild: false), 0, "a release build ignores a stored value")
        store.set("2", forKey: "gattWriteBurst")
        XCTAssertEqual(GattLinkSettings.storedWriteBurst(in: store, debugBuild: true), 2, "a launch argument arrives as a string")
        store.set(-3, forKey: "gattWriteBurst")
        XCTAssertEqual(GattLinkSettings.storedWriteBurst(in: store, debugBuild: true), 0, "a negative value is off")
    }
}
