import Foundation
import NearbyCore

/// DEBUG-only remote control through launch arguments (like Android's `test_*` extras), for runs over SSH:
///
///     xcrun devicectl device process launch --device <udid> --terminate-existing org.nearbyintercom.ios \
///         -NearbyAutoCall first -NearbyCallType voice -NearbyCallSeconds 30
///
/// Arguments:
/// - `-NearbyAutoCall first|<handle>|<short handle>|<12-hex prefix>`: call that person once discovered (60 s wait).
/// - `-NearbyCallType voice|video` (default voice); `-NearbyCallSeconds N`: hang up N s after the call is active (default 20).
/// - `-NearbyAutoAccept voice|video`: answer incoming calls automatically (every call while the app runs);
///   `-NearbyAnswerSeconds N` hangs an answered call up after N s (default: the caller hangs up).
/// - `-NearbyAvailable 1|0`: be reachable for calls (default unchanged).
/// - `-NearbyRequestPermissions 1`: ask for microphone and camera at launch (one human tap each, first time only).
/// - `-NearbyAutoWatch first|<handle>` and `-NearbyWatchSeconds N`: watch a stream.
/// - `-NearbyTransport gatt|l2cap`: transport to advertise; `-NearbyLabels 1`: experimental names and titles.
/// Every step is logged as `BENCHMARK auto_*`.
final class Automation {
    let args: [String: String]
    private weak var model: AppModel?
    private var timer: Timer?
    private var started = Date()
    private var callStartedAt: Date?
    private var callActiveAt: Date?
    private var done = false
    private var watchStartedAt: Date?
    private var acceptedCall: ObjectIdentifier?
    private var answeredActiveAt: Date?

    static func parse(_ arguments: [String]) -> [String: String] {
        var out: [String: String] = [:]
        var i = 0
        while i < arguments.count {
            let a = arguments[i]
            if a.hasPrefix("-Nearby"), i + 1 < arguments.count { out[String(a.dropFirst(7))] = arguments[i + 1]; i += 2 } else { i += 1 }
        }
        return out
    }

    init?(model: AppModel, arguments: [String] = ProcessInfo.processInfo.arguments) {
        #if DEBUG
        let parsed = Automation.parse(arguments)
        guard !parsed.isEmpty else { return nil }
        args = parsed; self.model = model
        #else
        return nil
        #endif
    }

    func start() {
        AppLog.event("auto_start", args)
        if let t = args["Transport"], let transport = MeshTransport(rawValue: t) { model?.transport = transport }
        if let available = args["Available"] { model?.availableForCalls = available == "1" }
        if let rot = args["RotatingIds"] { model?.rotatingIds = rot == "1" }
        if let fec = args["CallAudioFec"] { AppSettings.callAudioFec = fec == "1" }
        if let ladder = args["ResolutionLadder"] { AppSettings.resolutionLadder = ladder == "1" }
        if args["RequestPermissions"] == "1" { MediaPermissions.request(video: true, context: "launch") { _, _ in } }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func matches(_ target: String, prefixHex: String) -> Bool {
        if target == "first" { return true }
        if target.lowercased() == prefixHex.lowercased() { return true }
        guard let prefix = Data(hex: prefixHex), let handle = IdentityHandle.handle(prefix: prefix) else { return false }
        if let parsed = IdentityHandle.parse(target) { return parsed == prefix }
        if let short = IdentityHandle.parseShort(target) { return handle.hasPrefix(short) }
        return false
    }

    private func tick() {
        guard let model else { return }
        if let accept = args["AutoAccept"] {
            if let call = model.call, call.phase == .incomingRinging, acceptedCall != ObjectIdentifier(call) {
                acceptedCall = ObjectIdentifier(call); answeredActiveAt = nil
                AppLog.event("auto_accept", ["type": accept, "peer": call.peerPrefixHex ?? "?"])
                call.accept(as: accept == "video" ? .video : .voice)
            }
            if let call = model.call, acceptedCall == ObjectIdentifier(call), call.phase == .active {
                if answeredActiveAt == nil { answeredActiveAt = Date(); AppLog.event("auto_accept", ["result": "active"]) }
                if let limit = args["AnswerSeconds"].flatMap(Double.init), let since = answeredActiveAt, Date().timeIntervalSince(since) >= limit {
                    AppLog.event("auto_accept", ["result": "hang_up", "heldSeconds": String(format: "%.0f", Date().timeIntervalSince(since))])
                    call.logStats(); call.end()
                }
            }
        }
        guard !done else { return }
        let seconds = Double(args["CallSeconds"] ?? "20") ?? 20
        if let target = args["AutoCall"] {
            if callStartedAt == nil {
                if let person = model.people.first(where: { matches(target, prefixHex: $0.prefixHex) }) {
                    let type: CallType = args["CallType"] == "video" ? .video : .voice
                    AppLog.event("auto_call", ["target": target, "prefix": person.prefixHex, "handle": person.label.handle, "type": type.rawValue,
                                               "transport": person.transport.rawValue])
                    model.startCall(to: person, type: type)
                    callStartedAt = Date()
                } else if Date().timeIntervalSince(started) > 60 {
                    AppLog.event("auto_call", ["target": target, "result": "not_found", "people": "\(model.people.count)"]); finish()
                }
            } else if let call = model.call {
                if call.phase == .active && callActiveAt == nil { callActiveAt = Date(); AppLog.event("auto_call", ["result": "active"]) }
                if let active = callActiveAt, Date().timeIntervalSince(active) >= seconds {
                    AppLog.event("auto_call", ["result": "hang_up", "heldSeconds": String(format: "%.0f", Date().timeIntervalSince(active))])
                    call.logStats(); call.end(); finish()
                } else if callActiveAt == nil, Date().timeIntervalSince(callStartedAt!) > 90 {
                    AppLog.event("auto_call", ["result": "never_active", "phase": "\(String(describing: call.phase))"]); call.end(); finish()
                }
            } else if Date().timeIntervalSince(callStartedAt!) < 10 && callActiveAt == nil && model.callNotice == nil {
                // Permission request or connect still starting.
            } else {
                AppLog.event("auto_call", ["result": callActiveAt == nil ? "failed" : "call_gone", "notice": model.callNotice ?? "none"]); finish()
            }
        }
        if let target = args["AutoWatch"] {
            if watchStartedAt == nil, let row = model.streams.first(where: { matches(target, prefixHex: $0.announcement.prefixHex) }) {
                AppLog.event("auto_watch", ["target": target, "prefix": row.announcement.prefixHex]); model.startWatching(row); watchStartedAt = Date()
            } else if let s = watchStartedAt, Date().timeIntervalSince(s) >= (Double(args["WatchSeconds"] ?? "30") ?? 30) {
                AppLog.event("auto_watch", ["result": "stop"]); model.watch?.stop(); finish()
            }
        }
    }

    /// Stops the call/watch scenario; auto-accept keeps running while the app runs.
    private func finish() { done = true; if args["AutoAccept"] == nil { timer?.invalidate() }; AppLog.flush() }
}
