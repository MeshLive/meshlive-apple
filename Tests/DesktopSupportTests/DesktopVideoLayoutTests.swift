import XCTest
import CoreGraphics
@testable import DesktopSupport

final class DesktopVideoLayoutTests: XCTestCase {
    func testAsymmetricPictureTurnsClockwiseWithoutMirroring() {
        // Markers in an AppKit picture: top, right and an off-centre point. Fixed expected
        // positions distinguish 90 from 270 degrees and catch reflection as well as inversion.
        let markers = [CGPoint(x: 0, y: 30), CGPoint(x: 20, y: 0), CGPoint(x: -7, y: 11)]
        let cases: [(Int, [CGPoint])] = [
            (0, markers),
            (90, [CGPoint(x: 30, y: 0), CGPoint(x: 0, y: -20), CGPoint(x: 11, y: 7)]),
            (180, [CGPoint(x: 0, y: -30), CGPoint(x: -20, y: 0), CGPoint(x: 7, y: -11)]),
            (270, [CGPoint(x: -30, y: 0), CGPoint(x: 0, y: 20), CGPoint(x: -11, y: -7)])
        ]
        for (degrees, expected) in cases {
            let layout = DesktopVideoLayout(bounds: CGRect(x: 0, y: 0, width: 240, height: 426),
                                            clockwiseDegrees: degrees)
            for (marker, target) in zip(markers, expected) {
                let result = marker.applying(layout.transform)
                XCTAssertEqual(result.x, target.x, accuracy: 0.0001, "Angle \(degrees)")
                XCTAssertEqual(result.y, target.y, accuracy: 0.0001, "Angle \(degrees)")
            }
        }
    }

    func testQuarterTurnsFitTheSameViewportAfterResize() {
        for viewport in [CGRect(x: 0, y: 0, width: 288, height: 352),
                         CGRect(x: 12, y: 24, width: 900, height: 500)] {
            for degrees in [0, 90, 180, 270] {
                let layout = DesktopVideoLayout(bounds: viewport, clockwiseDegrees: degrees)
                XCTAssertEqual(layout.layerBounds.origin, .zero)
                let visible = layout.layerBounds.applying(layout.transform).standardized
                XCTAssertEqual(visible.width, viewport.width, accuracy: 0.0001)
                XCTAssertEqual(visible.height, viewport.height, accuracy: 0.0001)
                XCTAssertEqual(layout.position, CGPoint(x: viewport.midX, y: viewport.midY))
            }
        }
    }
}
