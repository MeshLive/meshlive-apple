import XCTest
@testable import MeshPeer

/// DEBUG `-NearbyAutoLive video|audio` starts the "Go live" choice the sheet would start; release builds ignore it.
final class AutoLiveRequestTests: XCTestCase {
    func testVideoAndAudioMapToTheSheetChoices() {
        XCTAssertEqual(AutoLiveRequest.from(["AutoLive": "video"], debugBuild: true), .go(audioOnly: false, title: nil))
        XCTAssertEqual(AutoLiveRequest.from(["AutoLive": "audio", "AutoLiveTitle": "Lane 4"], debugBuild: true),
                       .go(audioOnly: true, title: "Lane 4"))
        XCTAssertEqual(AutoLiveRequest.from(["AutoLive": "video", "AutoLiveTitle": "-"], debugBuild: true),
                       .go(audioOnly: false, title: ""), "`-` clears the title, as -NearbyAutoRadio")
    }

    func testAnUnknownModeIsRefusedNotGuessed() {
        XCTAssertEqual(AutoLiveRequest.from(["AutoLive": "both"], debugBuild: true), .invalid("both"))
    }

    func testReleaseBuildsAndRunsWithoutTheArgumentDoNothing() {
        XCTAssertNil(AutoLiveRequest.from(["AutoLive": "video"], debugBuild: false))
        XCTAssertNil(AutoLiveRequest.from(["AutoRadio": "x", "AutoLiveTitle": "t"], debugBuild: true))
    }
}
