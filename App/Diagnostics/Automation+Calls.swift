import Foundation
import NearbyCore

#if DEBUG
/// A6: DEBUG-only state for the unattended call hooks. One per Automation run.
struct CallHooks {
    var declinedCall: ObjectIdentifier?
    /// The ringing call the deadline belongs to (each call gets its own N seconds).
    var ringingCall: ObjectIdentifier?
    var declineDeadline: Date?
    var declineNoticePending = false
    var unknownActionLogged = false
    var autoAcceptIgnoredLogged = false
    var cancelledCall: ObjectIdentifier?
}

extension Automation {
    /// A6: the call hooks run before the existing AutoAccept block, so AutoAccept can win.
    func tickCallHooks(_ model: AppModel) {
        tickDecline(model)
        tickCancel(model)
    }

    /// `-NearbyAutoDecline plain|block|report` + `-NearbyDeclineAfterS N`: decline every incoming ring once, N seconds
    /// after this phone first sees it ringing (default 2; N may be 0). AutoAccept wins.
    private func tickDecline(_ model: AppModel) {
        guard let action = args["AutoDecline"] else { return }
        if args["AutoAccept"] != nil {
            if !callHooks.autoAcceptIgnoredLogged {
                callHooks.autoAcceptIgnoredLogged = true
                AppLog.event("auto_decline", ["result": "ignored_autoaccept"])
            }
            return
        }
        guard action == "plain" || action == "block" || action == "report" else {
            if !callHooks.unknownActionLogged {
                callHooks.unknownActionLogged = true
                AppLog.event("auto_decline", ["result": "unknown_action", "value": action])
            }
            return
        }
        if callHooks.declineNoticePending {
            callHooks.declineNoticePending = false
            AppLog.event("auto_decline", ["result": "done", "notice": model.callNotice ?? "none"])
        }
        guard let call = model.call, call.phase == .incomingRinging else { return }
        let id = ObjectIdentifier(call)
        if callHooks.declinedCall == id { return }
        let after = Double(args["DeclineAfterS"] ?? "2") ?? 2
        // Review fix: the deadline starts at the first tick that sees this call ring, and the call counts as handled
        // only once it is declined (marking it before the deadline left every call with N > 0 undeclined).
        if callHooks.ringingCall != id { callHooks.ringingCall = id; callHooks.declineDeadline = Date().addingTimeInterval(after) }
        guard let deadline = callHooks.declineDeadline, Date() >= deadline else { return }
        callHooks.declinedCall = id
        AppLog.event("auto_decline", ["action": action, "afterS": String(format: "%.0f", after),
                                       "peer": call.peerPrefixHex ?? "?", "fingerprint": call.fingerprint == nil ? "none" : "present"])
        switch action {
        case "block": model.declineAndBlock(call)
        case "report": model.declineAndReport(call)
        default: model.declineFromScreen(call)
        }
        callHooks.declineNoticePending = true
    }

    /// `-NearbyAutoCancelAfterS N`: with `-NearbyAutoCall`, end the call after N seconds if it never became active.
    private func tickCancel(_ model: AppModel) {
        guard let after = args["AutoCancelAfterS"].flatMap(Double.init), let started = callStartedAt,
              callActiveAt == nil, Date().timeIntervalSince(started) >= after,
              let call = model.call, call.phase != .active, call.phase != .ended else { return }
        let id = ObjectIdentifier(call)
        guard callHooks.cancelledCall != id else { return }
        callHooks.cancelledCall = id
        let phase = String(describing: call.phase)
        call.end()
        AppLog.event("auto_call", ["result": "cancelled", "phase": phase, "afterS": String(format: "%.0f", after)])
        finishCallHook()
    }
}
#endif
