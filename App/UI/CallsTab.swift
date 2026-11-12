import SwiftUI
#if os(iOS)
import UIKit
#endif
import NearbyCore

// MARK: - Calls

/// Calls tab: Nearby (the people you can call; a check mark only for your verified contacts) and Recent.
/// A row opens "Call <name>" with Voice call and Video call.
struct CallsTab: View {
    @EnvironmentObject var model: AppModel
    @Binding var showRecent: Bool
    #if os(macOS)
    @EnvironmentObject private var desktopNavigation: DesktopNavigation
    #endif
    @State private var addContact = false
    @State private var copiedPrompt: CopiedIdPrompt?
    @State private var blockNotPossible = false
    @State private var strangerActions = false
    @State private var askClearHistory = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var picked: PersonRow?
    @State private var blockTarget: BlockTarget?
    @State private var search = ""

    var body: some View {
        TabPage {
            TabHeader(title: "Calls")
            if !showRecent, let line = model.ownNearbyLine { OwnNearbyNameLine(text: line) }
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
            layout {
                Chip(title: "Nearby", selected: !showRecent) { showRecent = false }
                Chip(title: "Recent", selected: showRecent) { showRecent = true }
            }
            .padding(.vertical, 8)
            if !showRecent, model.bluetoothRestartNeeded { StatusCard(status: RadioStatus(model: model)) }
            CallNoticeCard()
            // Android StrangerCallFollowup: after a call with someone who is not saved, offer Add contact.
            if let name = model.strangerFollowUp {
                NoticeCard(text: "Add \(name) as a contact?", actionTitle: "Add", action: { model.strangerFollowUp = nil; openAddContact() }) {
                    model.strangerFollowUp = nil
                }
            }
            if showRecent { recent } else { nearby }
        }
        .debugPush("recent-none") { EmptyView() }
        .environment(\.nearbyRowActions, NearbyRowActions(
            call: { picked = $0 },
            start: { person, type in startNearbyCall(person, type) },
            addContact: { openAddContact() },
            block: { blockFromNearby($0, report: false) },
            report: { blockFromNearby($0, report: true) }))
        #if !os(macOS)
        .navigationDestination(isPresented: $addContact) { VerifyView() }
        #endif
        .blockConfirmation($blockTarget)
        .background(Color.clear.alert("More than one phone is using this ID",
                                      isPresented: Binding(get: { copiedPrompt != nil }, set: { if !$0 { copiedPrompt = nil } }),
                                      presenting: copiedPrompt) { prompt in
            Button("Call anyway") { model.startCall(to: prompt.person, type: prompt.type) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(AppPlatform.isMac ? "More than one nearby device is showing this ID. Check their ID with them in person before sharing anything private."
                                   : "More than one nearby phone is showing this ID. Check their ID with them in person before sharing anything private.")
        })
        .background(Color.clear.alert("Declined, but not blocked", isPresented: $blockNotPossible) {
            Button("Block all unknown callers") { model.blockUnknownCallers = true; model.callNotice = "Block unknown callers is on" }
            Button("Close", role: .cancel) {}
        } message: {
            Text("This caller's temporary ID can't be blocked for future calls. Turn on Block unknown callers to stop calls from people outside your verified contacts.")
        })
        .background(Color.clear.confirmationDialog("To call them again: open Calls when they're nearby, or add them as a contact",
                                                   isPresented: $strangerActions, titleVisibility: .visible) {
            Button("Open Calls") { showRecent = false }
            Button("Add contact") { openAddContact() }
            Button("Cancel", role: .cancel) {}
        })
        .background(Color.clear.alert("Clear your call history?", isPresented: $askClearHistory) {
            Button("Clear history") { model.clearRecentHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AppPlatform.isMac ? "Recent calls on this Mac are deleted. Contacts and blocked people stay."
                                   : "Recent calls on this phone are deleted. Contacts and blocked people stay.")
        })
        .background(
            Color.clear.confirmationDialog(picked.map { "Call \($0.label.title)" } ?? "Call",
                                isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } }),
                                titleVisibility: .visible, presenting: picked) { person in
                Button("Voice call") { startNearbyCall(person, .voice) }.desktopCallShortcut("a")
                Button("Video call") { startNearbyCall(person, .video) }.desktopCallShortcut("v")
                Button("Cancel", role: .cancel) {}
            }
        )
    }

    /// Android copied-ID warning: a second tap ("Call anyway") before calling an ID heard from two phones at once.
    private func startNearbyCall(_ person: PersonRow, _ type: CallType) {
        guard person.copiedId else { model.startCall(to: person, type: type); return }
        AppLog.event("people_call", ["event": "copied_id_prompt", "video": "\(type == .video)"])
        // After the Call dialog has closed (a second presentation in the same tap would be dropped).
        DispatchQueue.main.async { copiedPrompt = CopiedIdPrompt(person: person, type: type) }
    }

    /// Android Nearby menu Block / Report: a recognised contact is blocked (asked first) or reported at once; a temporary
    /// ID cannot be blocked one by one (Android `afterDeclineAndBlock(null)`).
    private func blockFromNearby(_ person: PersonRow, report: Bool) {
        guard let fingerprint = model.fingerprint(ofNearby: person) else { blockNotPossible = true; return }
        if report { model.report(fingerprint, streamRoute: nil) }
        else { blockTarget = BlockTarget(fingerprint: fingerprint, name: model.blockName(for: fingerprint)) }
    }

    /// Android stranger Recent row: how to reach them again, or (control arm `-strangerFollowUp NO`) the plain note.
    private func strangerTapped() {
        if AppSettings.labSwitch("strangerFollowUp", shipped: true) { strangerActions = true }
        else { model.callNotice = "This person was not saved. A new call from the same phone shows a new name, so there is nobody to call back." }
    }

    /// Add contact from Calls (Android `openAddContact`): the scan side, as the Contacts button.
    private func openAddContact() {
        #if os(macOS)
        desktopNavigation.detailPath.append(DesktopDetailRoute { VerifyView() })
        #else
        addContact = true
        #endif
    }

    @ViewBuilder private var nearby: some View {
        if let notice = model.callAccessNotice {
            NoticeCard(text: notice, actionTitle: model.callAccessNoticeOpensSettings ? "Open settings" : nil,
                       action: model.callAccessNoticeOpensSettings ? { AppPlatform.openSettings() } : nil) {
                model.callAccessNotice = nil
            }
        }
        if model.people.isEmpty {
            NearbyEmptyState()
                .padding(.top, 80)
        } else {
            // Android Calls search: with more than 8 people nearby (or a search typed), rows whose name contains the text.
            if NearbySearch.showsField(people: model.people.count, query: search) {
                TextField("Search people", text: $search)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 16).frame(minHeight: 48)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityIdentifier("nearbySearch")
                    .padding(.bottom, 4)
            }
            let shown = model.people.filter { NearbySearch.matches($0.label.title, query: search) }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, person in
                if index > 0 { ListDivider() }
                Button { picked = person } label: {
                    PersonRowView(person: person,
                                  voice: { model.startCall(to: person, type: .voice) },
                                  video: { model.startCall(to: person, type: .video) })
                }
                    .buttonStyle(.plain)
                    .disabled(model.call != nil)
            }
        }
    }

    @ViewBuilder private var recent: some View {
        if model.recentCalls.isEmpty {
            if model.recentUnreadable {
                // Android: a history this device cannot open is never written over; a tap offers to clear it.
                Button { askClearHistory = true } label: {
                    PlainEmptyState(icon: "clock", title: AppPlatform.isMac
                                    ? "Your call history cannot be opened on this Mac right now. Click to clear it."
                                    : "Your call history cannot be opened on this phone right now. Tap to clear it.")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("recentUnreadable")
                .padding(.top, 80)
            } else {
                PlainEmptyState(icon: "clock", title: "No calls yet").padding(.top, 80).accessibilityIdentifier("recentEmpty")
            }
        } else {
            ForEach(Array(model.recentCalls.enumerated()), id: \.element.id) { index, record in
                if index > 0 { ListDivider(inset: 38) }
                RecentCallRow(record: record) { strangerTapped() }
                    .contextMenu {
                        // Android: press and hold a row to block; only a row with a full identity (a verified contact).
                        if let fingerprint = model.fingerprint(ofRecent: record) {
                            Button("Block") { blockTarget = BlockTarget(fingerprint: fingerprint, name: model.blockName(for: fingerprint)) }
                            Button("Report") { blockTarget = BlockTarget(fingerprint: fingerprint, name: model.blockName(for: fingerprint)) }
                        }
                    }
            }
        }
    }
}

/// One person nearby: name (check mark only for a verified contact), where they are, and Android's two round call
/// buttons (voice dark, video white). Tapping the row still offers both calls. A rotating ID heard from two phones at
/// once says so (Android copied-ID warning) and its calls ask first; touch and hold (Control-click on a Mac) offers
/// Android's row menu: Call, Add contact, Block, Report.
struct PersonRowView: View {
    let person: PersonRow
    var voice: (() -> Void)?
    var video: (() -> Void)?
    /// Set by `CallsTab` (the menu and the copied-ID check); empty elsewhere.
    @Environment(\.nearbyRowActions) private var actions
    var body: some View {
        HStack(spacing: 12) {
            if voice != nil { IconDisc(icon: "person", size: 48) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(person.label.title).font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.leading)
                    if person.label.contactName != nil {
                        Image(systemName: "checkmark").font(.subheadline.weight(.bold)).foregroundStyle(Palette.ink)
                            .accessibilityLabel("Verified contact")
                    }
                }
                Text(person.routeText).font(.subheadline).foregroundStyle(Palette.dimInk)
                if person.copiedId {
                    Label("More than one phone is using this ID", systemImage: AppIcon.problem)
                        .font(.subheadline).foregroundStyle(Palette.ink)
                        .accessibilityIdentifier("copiedId-\(person.prefixHex)")
                }
            }
            Spacer(minLength: 8)
            if let voice, let video {
                RoundCallButton(icon: "phone", label: "Voice call \(person.label.title)", white: false) { start(.voice, voice) }
                RoundCallButton(icon: "video", label: "Video call \(person.label.title)", white: true) { start(.video, video) }
            } else {
                Image(systemName: "chevron.right").font(.body.weight(.semibold)).foregroundStyle(Palette.dimInk).accessibilityHidden(true)
            }
        }
        .padding(.vertical, 12).frame(minHeight: 72)
        .contentShape(Rectangle())
        .contextMenu {
            if let call = actions.call {
                Button("Call") { call(person) }
                if let add = actions.addContact { Button("Add contact") { add() } }
                if let block = actions.block { Button("Block") { block(person) } }
                if let report = actions.report { Button("Report") { report(person) } }
            }
        }
        .accessibilityElement(children: voice == nil ? .combine : .contain)
        .accessibilityIdentifier("person-\(person.prefixHex)")
        .accessibilityHint(AppPlatform.isMac ? "Click to call. Control-click for details." : "Tap to call. Touch and hold for details.")
    }

    /// The row's own call buttons go through the copied-ID check when `CallsTab` provides it.
    private func start(_ type: CallType, _ fallback: () -> Void) {
        if let start = actions.start { start(person, type) } else { fallback() }
    }
}

/// What a Nearby row's menu and call buttons do (set by `CallsTab`; empty elsewhere, so no menu shows).
struct NearbyRowActions {
    var call: ((PersonRow) -> Void)?
    var start: ((PersonRow, CallType) -> Void)?
    var addContact: (() -> Void)?
    var block: ((PersonRow) -> Void)?
    var report: ((PersonRow) -> Void)?
}

private struct NearbyRowActionsKey: EnvironmentKey { static let defaultValue = NearbyRowActions() }

extension EnvironmentValues {
    var nearbyRowActions: NearbyRowActions {
        get { self[NearbyRowActionsKey.self] }
        set { self[NearbyRowActionsKey.self] = newValue }
    }
}

/// A call waiting for "Call anyway" (Android copied-ID dialog).
struct CopiedIdPrompt: Identifiable {
    let person: PersonRow
    let type: CallType
    var id: UUID { person.id }
}

/// Calls › Nearby with nobody found (Android `people_empty_*`): what helps, and Search again, which restarts the scan.
struct NearbyEmptyState: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 4) {
            PlainEmptyState(icon: AppIcon.people, title: "No one found yet",
                            message: AppPlatform.isMac
                                ? "Ask the other person to open MeshLive. Stay within about 10 to 30 metres. Both devices need a current MeshLive. The list updates by itself."
                                : "Ask the other person to open MeshLive. Stay within about 10 to 30 metres. Both phones need a current MeshLive. The list updates by itself.")
            CapsuleButton(title: "Search again", kind: .dark) { model.searchAgain() }
                .frame(maxWidth: 280)
        }
    }
}

/// One recent call (Android `recentRow`): who, then "↗ Answered / Video, 5 min ago". A contact's row calls back on a tap
/// and with its round button; a stranger's row says "Not saved" and a tap explains how to reach them again
/// (`strangerTapped`); touch and hold blocks a contact (CallsTab).
struct RecentCallRow: View {
    @EnvironmentObject var model: AppModel
    let record: CallRecord
    var strangerTapped: () -> Void = {}
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let label = PeerLabel(prefix: Data(hex: record.prefixHex) ?? Data(count: 6), contactName: model.contactName(prefixHex: record.prefixHex))
        let title = record.isBlocked ? "Blocked call" : record.callable ? label.title : (record.name.map(GeneratedNameText.display) ?? OwnNearbyName.someoneNearby)
        let text = VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.body.weight(.medium)).foregroundStyle(Palette.ink)
            Text(detail).font(.subheadline).foregroundStyle(Palette.dimInk)
        }
        let callBack = Button { model.callBack(record) } label: {
            Image(systemName: record.video ? "video" : "phone").font(.title3).foregroundStyle(Palette.ink)
                .frame(width: 48, height: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Call back")
        .opacity(record.callable ? 1 : 0)
        .disabled(!record.callable)
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { text; callBack }
            } else {
                HStack(spacing: 14) {
                    Image(systemName: icon).foregroundStyle(Palette.dimInk).frame(width: 24).accessibilityHidden(true)
                    text
                    Spacer()
                    callBack
                }
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { tap() }
        .disabled(model.call != nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(description(title))
        .accessibilityAction { tap() }
        .accessibilityIdentifier(record.isBlocked ? "recent-blocked" : record.callable ? "recent-\(record.prefixHex)" : "recent-stranger")
    }
    private var icon: String {
        if record.isBlocked { return "hand.raised" }
        switch record.direction {
        case .outgoing: return "phone.arrow.up.right"
        case .incoming: return "phone.arrow.down.left"
        case .missed: return "phone.down"
        }
    }
    /// Android: "Video, 5 min ago" (a stranger: "Not saved · Video, 5 min ago") after the arrow and the outcome; a
    /// blocked call "Declined, 5 min ago".
    private var detail: String {
        let when = RelativeDateTimeFormatter().localizedString(for: record.at, relativeTo: Date())
        if record.isBlocked { return "Declined, \(when)" }
        let kind = "\(record.video ? "Video" : "Voice"), \(when)"
        let text = record.callable ? kind : "Not saved \u{00B7} \(kind)"
        let outcome = record.outcome.flatMap(RecentCallOutcome.init(rawValue:)) ?? RecentCallOutcome.legacy(missed: record.direction == .missed)
        return RecentCallOutcome.line(outgoing: record.direction == .outgoing, outcome: outcome, detail: text,
                                      complete: AppSettings.labSwitch("completeRecentCalls", shipped: true))
    }
    /// Android `recent_row_description` / `recent_stranger_row_description`.
    private func description(_ title: String) -> String {
        if record.isBlocked { return "\(title), \(detail)" }
        let hold = AppPlatform.isMac ? "Click to call again. Control-click to block." : "Tap to call again. Touch and hold to block."
        return record.callable ? "\(title), \(detail). \(hold)" : "\(title), \(detail). Not saved, so they can't be called back."
    }
    private func tap() {
        guard !record.isBlocked, model.call == nil else { return }
        if record.callable { model.callBack(record) } else { strangerTapped() }
    }
}
