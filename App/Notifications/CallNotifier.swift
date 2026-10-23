import Foundation
import UIKit
import UserNotifications
import NearbyCore

/// Local incoming-call alerts (CallAlertPolicy has the rules). One alert at a time, replaced or removed when the call
/// stops ringing. Accept and Decline act on the ringing CallController; Accept brings the app forward, because the
/// microphone and camera start only in the foreground. No internet push: a closed app cannot ring.
/// Main thread only (its callbacks hop to the main queue).
final class CallNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CallNotifier()
    private let center = UNUserNotificationCenter.current()
    private static let identifier = "incoming-call"
    weak var model: AppModel?
    private(set) var authorization: CallAlertPolicy.Authorization = .notDetermined
    var onAuthorizationChange: ((CallAlertPolicy.Authorization) -> Void)?
    /// What the ringing alert shows now, so a later type or name is re-posted silently and a ring-out becomes "Missed call".
    private var posted: CallAlertPolicy.Content?
    private var firstPostPending = false
    private static let firstPostDelay: TimeInterval = 0.3

    func configure(model: AppModel) {
        self.model = model
        center.delegate = self
        let accept = UNNotificationAction(identifier: CallAlertPolicy.acceptAction, title: "Accept", options: [.foreground])
        // Not `.destructive`: the system would draw it red, and red is reserved for live.
        let decline = UNNotificationAction(identifier: CallAlertPolicy.declineAction, title: "Decline", options: [])
        let category = UNNotificationCategory(identifier: CallAlertPolicy.categoryIdentifier, actions: [accept, decline], intentIdentifiers: [],
                                              hiddenPreviewsBodyPlaceholder: CallAlertPolicy.lockedPlaceholder, options: [])
        center.setNotificationCategories([category])
        refreshAuthorization()
    }

    func refreshAuthorization() {
        center.getNotificationSettings { settings in
            let value: CallAlertPolicy.Authorization
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: value = .authorized
            case .denied: value = .denied
            default: value = .notDetermined
            }
            DispatchQueue.main.async { self.authorization = value; self.onAuthorizationChange?(value) }
        }
    }

    /// Asks once at an understandable moment (CallAlertPolicy.shouldRequest); the Settings button always may ask.
    func requestIfAppropriate(_ moment: CallAlertPolicy.Moment) {
        guard CallAlertPolicy.shouldRequest(moment, authorization: authorization, alreadyAsked: AppSettings.callAlertsAsked) else { return }
        AppSettings.callAlertsAsked = true
        AppLog.event("call_alerts", ["event": "request", "moment": "\(moment)"])
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            AppLog.event("call_alerts", ["event": "answer", "granted": "\(granted)"])
            DispatchQueue.main.async { self.refreshAuthorization() }
        }
    }

    /// The call rings, or the app's state changed while it rings: post, keep or remove the alert.
    func update(for call: CallController?) {
        let ringing = call?.phase == .incomingRinging
        let active = UIApplication.shared.applicationState == .active
        guard let call, CallAlertPolicy.shouldPost(ringing: ringing, appActive: active, authorization: authorization) else {
            if call?.phase == .ended, posted != nil, !active {
                // Rang out in the background, unanswered: leave a missed-call entry in place of the ringing alert.
                post(CallAlertPolicy.missedContent(peerName: call?.label?.title, stranger: call?.label == nil), ringing: false, sound: false)
                posted = nil
                AppLog.event("call_alerts", ["event": "missed"])
            } else if !ringing { clear() }
            return
        }
        // The invitation always starts as video; voice (cameraOff) follows about 1 ms later and the banner keeps the
        // first text, so the first post waits a beat for it. Later changes (the caller's name) re-post silently.
        if posted == nil {
            guard !firstPostPending else { return }
            firstPostPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstPostDelay) { [weak self, weak call] in
                guard let self else { return }
                self.firstPostPending = false
                let active = UIApplication.shared.applicationState == .active
                guard let call, self.posted == nil,
                      CallAlertPolicy.shouldPost(ringing: call.phase == .incomingRinging, appActive: active, authorization: self.authorization) else { return }
                self.repost(for: call)
            }
            return
        }
        repost(for: call)
    }

    /// A call that rang on CallKit's screen (experimental) and went unanswered leaves the same missed-call entry.
    func postMissed(for call: CallController) {
        guard authorization == .authorized else { return }
        post(CallAlertPolicy.missedContent(peerName: call.label?.title, stranger: call.label == nil), ringing: false, sound: false)
        AppLog.event("call_alerts", ["event": "missed", "via": "callkit"])
    }

    private func repost(for call: CallController) {
        let text = CallAlertPolicy.content(voice: call.offeredType == .voice, peerName: call.label?.title, stranger: call.label == nil)
        guard text != posted else { return }
        post(text, ringing: true, sound: posted == nil)
        posted = text
        AppLog.event("call_alerts", ["event": "posted", "voice": "\(call.offeredType == .voice)"])
    }

    private func post(_ text: CallAlertPolicy.Content, ringing: Bool, sound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        if ringing { content.categoryIdentifier = CallAlertPolicy.categoryIdentifier }
        content.sound = sound ? .default : nil
        content.threadIdentifier = "calls"
        center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
    }

    func clear() {
        guard posted != nil else { return }
        posted = nil
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Frontmost, the call screen and ringer already show the call. Inactive (Control Center, Notification Center, a
        // system alert over the app, or on the way to the background) the alert must show, or it would be swallowed.
        DispatchQueue.main.async {
            completionHandler(UIApplication.shared.applicationState == .active ? [] : [.banner, .list, .sound])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            self.posted = nil
            AppLog.event("call_alerts", ["event": "action", "action": action])
            if let call = self.model?.call, call.phase == .incomingRinging {
                switch action {
                case CallAlertPolicy.acceptAction: call.accept(as: call.offeredType)
                case CallAlertPolicy.declineAction: call.decline()
                default: break // a tap opens the app on the ringing call screen
                }
            }
            completionHandler()
        }
    }
}
