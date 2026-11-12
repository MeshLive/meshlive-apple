import XCTest
@testable import NearbyCore

/// The distribution key decides whether About says updates come from the App Store, and the licence page lists every
/// component that is linked into the apps with the files it is shown from.
final class StoreDistributionTests: XCTestCase {
    func testOnlyTheArchiveValueIsAnAppStoreBuild() {
        XCTAssertEqual(StoreDistribution(infoValue: "appstore"), .appStore)
        XCTAssertEqual(StoreDistribution(infoValue: nil), .source)
        XCTAssertEqual(StoreDistribution(infoValue: ""), .source)
        XCTAssertEqual(StoreDistribution(infoValue: "$(MESHLIVE_DISTRIBUTION)"), .source, "an unsubstituted build setting")
        XCTAssertEqual(StoreDistribution(infoValue: "APPSTORE"), .source, "an unknown value never claims the App Store")
        XCTAssertEqual(StoreDistribution(infoValue: "source"), .source)
    }

    func testTheLicencePageListsEveryLinkedComponentWithItsFiles() {
        let entries = OpenSourceNotices.entries
        XCTAssertEqual(entries.map(\.id), ["meshlive", "opus", "libvpx", "unicode", "webrtc", "android-names"])
        for entry in entries {
            XCTAssertFalse(entry.title.isEmpty)
            XCTAssertFalse(entry.licence.isEmpty)
            XCTAssertFalse(entry.resources.isEmpty, "\(entry.id) has at least one bundled licence file")
            XCTAssertTrue(entry.resources.allSatisfy { !$0.isEmpty })
        }
        XCTAssertEqual(entries.first?.resources, ["LICENSE", "LICENSE-EXCEPTION.md"], "MeshLive's own texts come first")
        XCTAssertTrue(entries.contains { $0.resources.contains("WEBRTC-LICENSE") })
        let listed = entries.map { entry in entry.title + " " + entry.licence }.joined(separator: " ").lowercased()
        for testOnly in ["bouncy", "json-java", "junit", "hamcrest", "noise-c"] {
            XCTAssertFalse(listed.contains(testOnly), "test-only components are not in the app's licence page")
        }
    }
}
