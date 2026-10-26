import XCTest
@testable import NearbyMedia

final class CameraSelectionTests: XCTestCase {
    func testExplicitCameraWinsOverAutomatic() {
        XCTAssertEqual(CameraSelection.selectedID(preferred: "external", available: ["built-in", "external"], defaultID: "built-in"), "external")
    }
    func testDisconnectedSelectionDoesNotFallBack() {
        XCTAssertNil(CameraSelection.selectedID(preferred: "external", available: ["built-in"], defaultID: "built-in"))
    }
    func testAutomaticUsesAvailableDefaultThenFirstLocalCamera() {
        XCTAssertEqual(CameraSelection.selectedID(preferred: "", available: ["external", "built-in"], defaultID: "built-in"), "built-in")
        XCTAssertEqual(CameraSelection.selectedID(preferred: "", available: ["external"], defaultID: "missing"), "external")
    }
    func testNoLocalCamera() {
        XCTAssertNil(CameraSelection.selectedID(preferred: "", available: [], defaultID: "missing"))
    }
}
