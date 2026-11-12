import XCTest
@testable import NearbyCore

/// The title-bar status (Android `statusKind`): one state at a time, the most important first.
final class StatusIndicatorTests: XCTestCase {
    func testAllWellIsReadyAndShowsOnlyTheDot() {
        let kind = StatusKind.of(readiness: .ready, hidden: false, relayPaused: false, hot: false)
        XCTAssertEqual(kind, .ready)
        XCTAssertFalse(kind.problem)
        XCTAssertNil(kind.word(mac: false))
        XCTAssertNil(kind.word(mac: true))
    }

    func testBluetoothComesBeforeEverythingElse() {
        let readiness: [(StatusReadiness, StatusKind)] = [(.unsupported, .bluetoothUnavailable), (.bluetoothOff, .bluetoothOff),
                                                          (.permissionsNeeded, .permissions), (.bluetoothProblem, .bluetoothProblem)]
        for (state, expected) in readiness {
            XCTAssertEqual(StatusKind.of(readiness: state, hidden: true, relayPaused: true, hot: true, screen: .live), expected, "\(state)")
        }
    }

    func testTheScreenThatOwnsTheRadioComesBeforeHidden() {
        XCTAssertEqual(StatusKind.of(readiness: .ready, hidden: true, relayPaused: false, hot: true, screen: .watching), .watching)
        XCTAssertEqual(StatusKind.of(readiness: .ready, hidden: true, relayPaused: false, hot: true, screen: .live), .live)
    }

    func testHiddenThenRelayPausedThenHot() {
        XCTAssertEqual(StatusKind.of(readiness: .ready, hidden: true, relayPaused: true, hot: true), .hidden)
        XCTAssertEqual(StatusKind.of(readiness: .ready, hidden: false, relayPaused: true, hot: true), .relayPaused)
        XCTAssertEqual(StatusKind.of(readiness: .ready, hidden: false, relayPaused: false, hot: true), .hot)
    }

    func testEveryProblemHasAWordOnBothPlatforms() {
        for kind in StatusKind.allCases where kind.problem {
            XCTAssertNotNil(kind.word(mac: false), "\(kind)")
            XCTAssertNotNil(kind.word(mac: true), "\(kind)")
        }
    }
}
