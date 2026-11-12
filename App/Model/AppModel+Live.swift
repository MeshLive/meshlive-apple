import Foundation
import NearbyCore

/// C1.2: a dismissible Live-page notice. "The stream was lost ..." offers Try again (a rescan); the radio block note
/// offers nothing. `closesWatch` closes the watch screen when the notice appears.
struct LiveNotice: Equatable, Identifiable {
    let id = UUID()
    var text: String
    var offersRescan: Bool
    var closesWatch: Bool
}

// Live track (C1): AppModel code for live streams goes here.
extension AppModel {
    /// C1.1: read each time, so a DEBUG launch argument works and a release build is always watch-only.
    var sourceGate: StreamSourceGate { StreamSourceGate(sourceRoles: ReleaseGates.sourceRoles) }

    /// C1.2: the lost-stream end: the stream played (no failed-join retry is queued), the list says what happened, and
    /// Try again rescans. The failed-join flow (`streamNotice`, `streamRetryTarget`) stays exactly BASE's.
    func noteStreamLost(_ controller: WatchController) {
        streamJoinRetry.onJoined(LogicalStreamTarget(controller.offer))
        liveNotice = LiveNotice(text: StreamSearchBound.lostNotice, offersRescan: true, closesWatch: true)
    }

    /// Try again on the lost-stream notice: flush the duplicate filter so a re-advertising source is reported promptly,
    /// then remove the notice. It rescans for nearby streams; it never rejoins the lost stream.
    func rescanStreams() {
        radio.restartScan()
        AppLog.event("stream_search", ["event": "rescan"])
        liveNotice = nil
    }

    func dismissLiveNotice() { liveNotice = nil }
}
