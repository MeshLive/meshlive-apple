import Foundation
#if os(iOS)
import UIKit
#endif
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
    private var posted = false

    func configure(model: AppModel) {
        guard !DesktopPreview.enabled else { return }
        self.model = model
        center.delegate = self
        let accept = UNNotificationAction(identifier: CallAlertPolicy.acceptAction, title: "Accept", options: [.foreground])
        // Not `.destructive`: the system would draw it red, and red is reserved for live.
        let decline = UNNotificationAction(identifier: CallAlertPolicy.declineAction, title: "Decline", options: [])
        let category = UNNotificationCategory(identifier: CallAlertPolicy.categoryIdentifier, actions: [accept, decline], intentIdentifiers: [],
                                              hiddenPreviewsBodyPlaceholder: CallAlertPolicy.lockedPlaceholder, options: [])
        // Missed calls (MissedCallAlert): Call back dials the caller again when they are still nearby.
        let callBack = UNNotificationAction(identifier: MissedCallAlert.callBackAction, title: "Call back", options: [.foreground])
        let missed = UNNotificationCategory(identifier: MissedCallAlert.categoryIdentifier, actions: [callBack], intentIdentifiers: [],
                                            hiddenPreviewsBodyPlaceholder: MissedCallAlert.lockedPlaceholder, options: [])
        let missedPlain = UNNotificationCategory(identifier: MissedCallAlert.plainCategoryIdentifier, actions: [], intentIdentifiers: [],
                                                 hiddenPreviewsBodyPlaceholder: MissedCallAlert.lockedPlaceholder, options: [])
        center.setNotificationCategories([category, missed, missedPlain])
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
        guard !DesktopPreview.enabled, !EmergencyWipe.happened else { return }
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
        guard !DesktopPreview.enabled, !EmergencyWipe.happened else { return }
        let ringing = call?.phase == .incomingRinging
        let active = AppPlatform.active
        guard let call, CallAlertPolicy.shouldPost(ringing: ringing, appActive: active, authorization: authorization) else {
            if !ringing { clear() }
            return
        }
        guard !posted else { return }
        let text = CallAlertPolicy.content(voice: call.offeredType == .voice, peerName: call.label?.title, stranger: call.label == nil)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.categoryIdentifier = CallAlertPolicy.categoryIdentifier
        content.sound = .default
        content.threadIdentifier = "calls"
        #if os(macOS)
        DesktopCallAlertLevel.apply(to: content) // Time Sensitive only with Apple's entitlement (Desktop/DesktopRingPanel.swift)
        #endif
        center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
        posted = true
        AppLog.event("call_alerts", ["event": "posted", "voice": "\(call.offeredType == .voice)"])
    }

    /// An incoming call stopped ringing without being answered or declined here: one notification per caller, with
    /// the number of calls missed while it is still showing. Needs the call-alert permission; never asks for it.
    func postMissed(peerName: String?, stranger: Bool, prefixHex: String?, video: Bool) {
        guard !DesktopPreview.enabled, !EmergencyWipe.happened else { return }
        guard authorization == .authorized else {
            AppLog.event("missed_call", ["posted": "false", "reason": "no_permission"]); return
        }
        let identifier = MissedCallAlert.identifier(prefixHex: prefixHex)
        center.getDeliveredNotifications { delivered in
            let previous = delivered.first { $0.request.identifier == identifier }?.request.content.userInfo[MissedCallAlert.countKey] as? Int
            let count = MissedCallAlert.nextCount(stillShowing: previous != nil, previous: previous ?? 0)
            let content = UNMutableNotificationContent()
            content.title = MissedCallAlert.title(peerName: peerName, stranger: stranger, count: count)
            // Call back only when there is a verified contact to call.
            content.categoryIdentifier = prefixHex != nil && !stranger ? MissedCallAlert.categoryIdentifier : MissedCallAlert.plainCategoryIdentifier
            content.threadIdentifier = "missed-calls"
            content.sound = .default
            var info: [String: Any] = [MissedCallAlert.countKey: count, MissedCallAlert.videoKey: video]
            if let prefixHex, !stranger { info[MissedCallAlert.prefixKey] = prefixHex }
            content.userInfo = info
            self.center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            AppLog.event("missed_call", ["posted": "true", "count": "\(count)", "named": "\(!stranger && peerName != nil)"])
        }
    }

    /// The emergency wipe: every delivered and pending notification of this app goes (missed calls name peers).
    func removeAllForWipe() {
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
        posted = false
    }

    func clear() {
        guard posted else { return }
        posted = false
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Frontmost, the call screen and ringer already show the call. Inactive (Control Center, Notification Center, a
        // system alert over the app, or on the way to the background) the alert must show, or it would be swallowed.
        let missed = MissedCallAlert.isMissedCategory(notification.request.content.categoryIdentifier)
        DispatchQueue.main.async {
            // A missed call stays in the list even while MeshLive is frontmost (the call screen already said so).
            if missed { completionHandler(AppPlatform.active ? [.list] : [.banner, .list, .sound]); return }
            completionHandler(AppPlatform.active ? [] : [.banner, .list, .sound])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let content = response.notification.request.content
        if MissedCallAlert.isMissedCategory(content.categoryIdentifier) {
            let prefix = content.userInfo[MissedCallAlert.prefixKey] as? String
            let video = content.userInfo[MissedCallAlert.videoKey] as? Bool ?? false
            DispatchQueue.main.async {
                AppLog.event("missed_call", ["event": "action", "action": action])
                if action == MissedCallAlert.callBackAction, let prefix, let model = self.model, model.call == nil {
                    model.callBack(CallRecord(prefixHex: prefix, direction: .missed, video: video, at: Date(), seconds: 0))
                }
                completionHandler()
            }
            return
        }
        DispatchQueue.main.async {
            self.posted = false
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
