import XCTest
@testable import NearbyCore

/// B1.1: every camera authorization state has one gate and one honest message; the scanner prompt is the existing one.
final class QrScannerPermissionTests: XCTestCase {
    private let states: [QrScannerCamera] = [.authorized, .denied, .restricted, .notDetermined, .unknown]

    func testEveryCameraStateHasOneGate() {
        XCTAssertEqual(QrScannerPermission.gate(.authorized), .scan)
        XCTAssertEqual(QrScannerPermission.gate(.notDetermined), .request)
        XCTAssertEqual(QrScannerPermission.gate(.denied), .blocked(opensSettings: true))
        XCTAssertEqual(QrScannerPermission.gate(.restricted), .blocked(opensSettings: false))
        XCTAssertEqual(QrScannerPermission.gate(.unknown), .blocked(opensSettings: false))
    }

    func testTheBlockedMessagesAreDistinctAndTheDeniedOneNamesThePlatformSettings() {
        XCTAssertEqual(QrScannerPermission.message(.authorized, mac: false), "")
        XCTAssertEqual(QrScannerPermission.message(.authorized, mac: true), "")

        let blocked: [QrScannerCamera] = [.denied, .restricted, .unknown, .notDetermined]
        let messages = blocked.map { QrScannerPermission.message($0, mac: false) }
        for message in messages {
            XCTAssertFalse(message.isEmpty)
        }
        for i in messages.indices {
            for j in messages.indices where i < j {
                XCTAssertNotEqual(messages[i], messages[j])
            }
        }

        let deniedPhone = QrScannerPermission.message(.denied, mac: false)
        let deniedMac = QrScannerPermission.message(.denied, mac: true)
        XCTAssertNotEqual(deniedPhone, deniedMac)
        XCTAssertTrue(deniedPhone.contains("Settings"))
        XCTAssertTrue(deniedMac.contains("System Settings"))
        XCTAssertFalse(QrScannerPermission.message(.restricted, mac: false).contains("Settings"))
        XCTAssertFalse(QrScannerPermission.message(.unknown, mac: false).contains("Settings"))
        XCTAssertFalse(QrScannerPermission.message(.notDetermined, mac: false).contains("Settings"))
    }

    func testTheFixtureNamesMapToTheStates() {
        XCTAssertEqual(QrScannerCamera(fixture: "authorized"), .authorized)
        XCTAssertEqual(QrScannerCamera(fixture: "denied"), .denied)
        XCTAssertEqual(QrScannerCamera(fixture: "restricted"), .restricted)
        XCTAssertEqual(QrScannerCamera(fixture: "notDetermined"), .notDetermined)
        XCTAssertEqual(QrScannerCamera(fixture: "unknown"), .unknown)
        XCTAssertNil(QrScannerCamera(fixture: "allowed"))
        XCTAssertNil(QrScannerCamera(fixture: ""))
    }

    func testThePromptIsTheExistingOne() {
        XCTAssertEqual(QrScannerPermission.prompt, "Point the camera at the other person's code")
    }
}
