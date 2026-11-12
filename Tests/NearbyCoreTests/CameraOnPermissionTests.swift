import XCTest
@testable import NearbyCore

/// B1F step 1: "Camera on" in a voice call asks once when the camera state is still undetermined, starts on the grant,
/// and tells with Settings only when the answer is denied (a restriction never offers Settings).
final class CameraOnPermissionTests: XCTestCase {
    func testCameraOnRequestsWhenTheStateIsStillUndetermined() {
        XCTAssertEqual(CallMediaAccess.cameraOn(CallMediaAccess.Access(granted: false, canAskAgain: true)), .request)
    }

    func testAGrantedCameraStarts() {
        XCTAssertEqual(CallMediaAccess.cameraOn(CallMediaAccess.Access(granted: true)), .start)
    }

    func testADeniedCameraTellsAndOffersSettings() {
        XCTAssertEqual(CallMediaAccess.cameraOn(CallMediaAccess.Access(granted: false, canAskAgain: false)),
                       .tell(opensSettings: true))
    }

    func testARestrictedCameraTellsWithoutSettings() {
        XCTAssertEqual(CallMediaAccess.cameraOn(CallMediaAccess.Access(granted: false, canAskAgain: false, restricted: true)),
                       .tell(opensSettings: false))
    }
}
