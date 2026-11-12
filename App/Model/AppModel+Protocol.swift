import Foundation
import NearbyCore

// Protocol track (D1, D2): AppModel code for join keys and link renewal goes here.
extension AppModel {
    // MARK: D1 viewer join keys (Design SI phase 1, viewer side; `ReleaseGates.streamJoinKeys`, off)
    //
    // A watch session presents a throwaway join key J at both BMH2 layers of every stream hop, and its viewer requests
    // carry J's IDs: a version 2 request nodeId(J)'s prefix with capability summary 0, a version 5 (compact v2) request
    // entry(Ks, nodeId(J), e, 2). Rejoin, recovery and epoch boundaries keep the session's keys; every end of the watch
    // closes them (`StreamJoinSessions`). Nothing is persisted; only a DEBUG build logs J's prefix (`stream_key`).

    /// The keys of a watch that starts now, or nil with the gate off (the watch presents this device's identity, as
    /// before). The gate is read once per watch: a change applies from the next watch, never in the middle of one.
    func beginJoinKeys() -> StreamJoinKeys? {
        guard ReleaseGates.streamJoinKeys else { return nil }
        let keys = joinSessions.begin()
        noteJoinKeysPresented(keys, reason: .watch)
        return keys
    }

    /// The `stream_key` line (PROTOCOL A.9): J's prefix and the session number only in a DEBUG build.
    static func logJoinKeys(_ keys: StreamJoinKeys, _ event: StreamJoinKeys.KeyEvent, reason: String, role: StreamJoinKeys.Role) {
        AppLog.event("stream_key", keys.logLine(event, reason: reason, role: role, debugBuild: LabSwitch.isDebugBuild))
    }

    /// J is presented: a new watch, a recovery rejoin, or this watch's forwarder offer.
    func noteJoinKeysPresented(_ keys: StreamJoinKeys, reason: StreamJoinKeys.OpenReason, role: StreamJoinKeys.Role = .viewer) {
        Self.logJoinKeys(keys, .open, reason: reason.rawValue, role: role)
    }

    /// Where a waiting viewer's role-2 entries come from: J's (keyed by Ks) for a join-key watch, else `presenceEntry`
    /// (this device's presence-keyed entries, as before). Nil when the watch's keys are already closed: nothing is
    /// advertised then, never a presence-keyed request instead.
    func viewerRequestEntries(for watch: WatchController, epoch: Int64,
                              presenceEntry: @escaping (Int64) -> OpeningEntry) -> ((Int64) -> OpeningEntry)? {
        guard let keys = watch.joinKeys else { return presenceEntry }
        guard let entries = keys.viewerRequestEntries(epoch: epoch) else {
            AppLog.event("rotating_ids", ["event": "request_refused", "role": "viewer", "reason": "join_keys_closed"])
            return nil
        }
        return entries
    }

    /// A join-key watch's request to a version 2 offer: nodeId(J)'s prefix and capability summary 0; nil when it cannot
    /// be built (nothing goes on air then, never this device's fixed prefix).
    func joinKeyVersionTwoRequest(_ watch: WatchController) -> DiscoveryAnnouncement? {
        guard let keys = watch.joinKeys else { return nil }
        do {
            return try StreamJoinRequest.versionTwo(keys: keys, offer: watch.offer, transport: watch.transport)
        } catch {
            AppLog.event("rotating_ids", ["event": "request_refused", "role": "viewer", "reason": "join_keys_version_2"])
            return nil
        }
    }

    /// The watch ended (`WatchController.finish`): its keys close at once (Ks zeroed, J stops signing).
    func endJoinKeys(_ keys: StreamJoinKeys, reason: StreamJoinSessions.EndReason) {
        joinSessions.close(keys, reason: reason)
    }

    /// The finished watch is handed back: J's pinned role-2 entries are dropped now rather than at the next join.
    func dropJoinKeyPins(after controller: WatchController) {
        guard controller.joinKeys != nil else { return }
        rotating.viewerRequest.startJoin(elapsedMs: RotatingDiscoveryRuntime.elapsedMs)
    }
}
