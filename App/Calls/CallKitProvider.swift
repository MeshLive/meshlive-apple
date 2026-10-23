import Foundation
import UIKit
import AVFoundation
import CallKit
import NearbyCore

/// EXPERIMENTAL (Settings > Experiments, off): an incoming call that rings while MeshLive is in the background shows the
/// iPhone's native call screen (lock screen, Dynamic Island, system ringtone) instead of the local alert. CallKitPolicy
/// has the rules. A call answered here gets its audio session from CallKit (provider(_:didActivate:)). No PushKit: a
/// closed app still cannot ring. One call at a time, like the app. Main thread only (the delegate runs on main).
final class CallKitProvider: NSObject, CXProviderDelegate {
    static let shared = CallKitProvider()
    private lazy var provider: CXProvider = {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        let provider = CXProvider(configuration: configuration)
        provider.setDelegate(self, queue: nil)
        return provider
    }()
    private let controller = CXCallController()
    private weak var call: CallController?
    private var uuid: UUID?
    private var shown: CallKitPolicy.Update?
    private var answered = false
    private var reportPending = false
    /// Same beat as CallNotifier: the invitation starts as video and the voice signal follows about 1 ms later.
    private static let firstReportDelay: TimeInterval = 0.3

    /// The call's phase, type or name changed, or the app's state did. True when CallKit shows (or is about to show)
    /// this call: the local alert and the app's ringer then stay quiet.
    func update(for call: CallController) -> Bool {
        if uuid != nil, self.call === call {
            guard call.phase != .ended, call.ended == nil else { return true } // callEnded(_:) reports it with its reason
            switch CallKitPolicy.outcome(ringing: call.phase == .incomingRinging, ended: false, answeredByCallKit: answered, endedInApp: false, failed: false) {
            case .keep: refresh(call); return true
            case .report(let reason): end(reason); return false
            case .requestEnd: return false
            }
        }
        if reportPending, self.call === call { return true }
        let active = UIApplication.shared.applicationState == .active
        guard uuid == nil, CallKitPolicy.shouldReport(enabled: AppSettings.callKit, ringing: call.phase == .incomingRinging, appActive: active) else { return false }
        self.call = call; reportPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstReportDelay) { [weak self, weak call] in
            guard let self else { return }
            self.reportPending = false
            guard let call, self.call === call, call.phase == .incomingRinging, call.ended == nil else { return }
            self.report(call)
        }
        return true
    }

    /// The call is over (every end path, after its reason is known): close the native screen to match.
    func callEnded(_ call: CallController) {
        guard self.call === call else { return }
        reportPending = false
        guard uuid != nil else { self.call = nil; return }
        switch CallKitPolicy.outcome(ringing: false, ended: true, answeredByCallKit: answered, endedInApp: call.endedInApp, failed: call.failedEarly) {
        case .keep: break
        case .report(let reason):
            if reason == .unanswered { CallNotifier.shared.postMissed(for: call) }
            end(reason)
        case .requestEnd:
            guard let uuid else { return }
            controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { error in
                AppLog.event("callkit", ["event": "end_request", "error": error.map { "\(($0 as NSError).code)" } ?? "none"])
            }
        }
    }

    private func report(_ call: CallController) {
        let id = UUID()
        uuid = id; answered = false
        let update = content(for: call)
        shown = update
        provider.reportNewIncomingCall(with: id, update: cxUpdate(update)) { [weak self] error in
            DispatchQueue.main.async {
                AppLog.event("callkit", ["event": "reported", "video": "\(update.hasVideo)", "named": "\(update.callerName != nil)",
                                         "error": error.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "none"])
                // Refused (Do Not Disturb, a missing entitlement): the call still rings on the app's own screen.
                if error != nil, self?.uuid == id { self?.forget() }
            }
        }
    }

    private func refresh(_ call: CallController) {
        guard let uuid else { return }
        let update = content(for: call)
        guard update != shown else { return }
        shown = update
        provider.reportCall(with: uuid, updated: cxUpdate(update))
        AppLog.event("callkit", ["event": "updated", "video": "\(update.hasVideo)", "named": "\(update.callerName != nil)"])
    }

    private func end(_ reason: CallKitPolicy.EndReason) {
        guard let uuid else { return }
        let cx: CXCallEndedReason
        switch reason {
        case .failed: cx = .failed
        case .remoteEnded: cx = .remoteEnded
        case .unanswered: cx = .unanswered
        case .answeredElsewhere: cx = .answeredElsewhere
        case .declinedElsewhere: cx = .declinedElsewhere
        }
        provider.reportCall(with: uuid, endedAt: Date(), reason: cx)
        AppLog.event("callkit", ["event": "ended", "reason": "\(reason)"])
        forget()
    }

    private func forget() { uuid = nil; call = nil; shown = nil; answered = false }

    private func content(for call: CallController) -> CallKitPolicy.Update {
        CallKitPolicy.update(voice: call.offeredType == .voice, peerName: call.label?.title, stranger: call.label == nil)
    }

    private func cxUpdate(_ update: CallKitPolicy.Update) -> CXCallUpdate {
        let cx = CXCallUpdate()
        cx.localizedCallerName = update.callerName
        cx.hasVideo = update.hasVideo
        cx.supportsHolding = false; cx.supportsGrouping = false; cx.supportsUngrouping = false; cx.supportsDTMF = false
        return cx
    }

    // MARK: CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        AppLog.event("callkit", ["event": "reset"])
        forget()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard action.callUUID == uuid, let call, call.phase == .incomingRinging else { action.fail(); return }
        answered = true
        AppLog.event("callkit", ["event": "answer", "video": "\(call.offeredType == .video)"])
        call.answeredByCallKit = true
        // Apple's order: set the category now, CallKit activates the session after this action (CallAudio finishes it).
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: call.offeredType == .video ? .videoChat : .voiceChat,
                                                          options: [.allowBluetoothHFP, .allowBluetoothA2DP])
        call.accept(as: call.offeredType)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard action.callUUID == uuid else { action.fulfill(); return }
        let call = self.call
        AppLog.event("callkit", ["event": "end", "answered": "\(answered)"])
        forget()
        if let call, call.ended == nil { call.phase == .incomingRinging ? call.decline() : call.end() }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard action.callUUID == uuid, let call else { action.fail(); return }
        call.setMuted(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        AppLog.event("callkit", ["event": "audio_activated", "category": audioSession.category.rawValue])
        call?.callKitAudioActivated()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        AppLog.event("callkit", ["event": "audio_deactivated"])
    }
}
