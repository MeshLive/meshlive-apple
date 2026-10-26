import Foundation
import MetricKit
import CryptoKit
import SwiftUI
import NearbyCore

/// Crash reports on the next launch (Android CrashReports, 2026-10-21; `CrashReport` has the content rules). MetricKit
/// delivers a diagnostic payload after a crash; each crash becomes a short scrubbed text in Application Support
/// (excluded from backups). The next launch asks "MeshLive closed unexpectedly. Share a crash report?" and shows the
/// exact text. Share opens the system share sheet: nothing is sent unless the user sends it. "Not now" drops that
/// report; "Don't ask again" turns reports off and deletes the kept ones. Reports older than 7 days are deleted.
/// Default on (as Android); control arm `-crashReports NO`. Never in the DEBUG preview.
final class CrashReports: NSObject, ObservableObject, MXMetricManagerSubscriber {
    static let shared = CrashReports()
    private let defaults = DesktopPreview.preferences
    /// The report waiting for the user's answer (the oldest kept one).
    @Published private(set) var pending: String?
    private var started = false

    var enabled: Bool { AppSettings.flag("crashReports", default: true, in: defaults) }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("crash-reports", isDirectory: true)
    }

    func start() {
        guard !started, !DesktopPreview.enabled, enabled else { return }
        started = true
        #if DEBUG
        if RootView.debugArgument("-NearbyCrashReportFixture") == "1" { keep(CrashReports.fixture) }
        #endif
        MXMetricManager.shared.add(self)
        store(MXMetricManager.shared.pastDiagnosticPayloads)
        refresh()
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard !EmergencyWipe.happened else { return }
        store(payloads)
        DispatchQueue.main.async { self.refresh() }
    }

    /// Share or Not now: this report is answered and deleted.
    func answered(shared: Bool) {
        AppLog.event("crash_report", ["event": shared ? "shared" : "not_now"])
        if let first = files().first { try? FileManager.default.removeItem(at: first) }
        refresh()
    }

    /// Don't ask again: no more reports are kept or offered, and the kept ones are deleted.
    func disable() {
        AppLog.event("crash_report", ["event": "disabled"])
        defaults.set(false, forKey: "crashReports")
        MXMetricManager.shared.remove(self)
        try? FileManager.default.removeItem(at: Self.directory)
        pending = nil
    }

    private func store(_ payloads: [MXDiagnosticPayload]) {
        guard enabled else { return }
        for payload in payloads {
            for text in CrashReport.reports(fromPayloadJSON: payload.jsonRepresentation()) { keep(text) }
        }
    }

    /// One file per report, named by its content hash so a payload delivered twice is kept once; a report already
    /// answered is not kept again.
    /// The emergency wipe: stop receiving and delete every kept report (the sweep would too; this also stops later
    /// deliveries in this run).
    func wipe() {
        MXMetricManager.shared.remove(self)
        try? FileManager.default.removeItem(at: Self.directory)
        DispatchQueue.main.async { self.pending = nil }
    }

    private func keep(_ text: String) {
        guard !EmergencyWipe.happened else { return }
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        var seen = defaults.stringArray(forKey: "crashReportsSeen") ?? []
        guard !seen.contains(hash) else { return }
        seen.append(hash); defaults.set(Array(seen.suffix(50)), forKey: "crashReportsSeen")
        var dir = Self.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        BackupExclusion.apply(&dir)
        let name = "\(Int(Date().timeIntervalSince1970))-\(hash.prefix(12)).txt"
        try? Data(text.utf8).write(to: dir.appendingPathComponent(name), options: .atomic)
        AppLog.event("crash_report", ["event": "kept", "characters": "\(text.count)"])
    }

    private func files() -> [URL] {
        let fm = FileManager.default
        let all = (try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let cutoff = Date().addingTimeInterval(-CrashReport.keepSeconds)
        var kept: [(URL, Date)] = []
        for url in all where url.pathExtension == "txt" {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            if created < cutoff { try? fm.removeItem(at: url) } else { kept.append((url, created)) }
        }
        return kept.sorted { $0.1 < $1.1 }.map(\.0)
    }

    private func refresh() {
        pending = enabled ? files().first.flatMap { try? String(contentsOf: $0, encoding: .utf8) } : nil
    }

    #if DEBUG
    /// UI-test sample (`-NearbyCrashReportFixture 1`), made by the same parser from a made-up payload.
    static var fixture: String {
        let json: [String: Any] = ["crashDiagnostics": [[
            "diagnosticMetaData": ["appVersion": "0.0.0", "osVersion": "Test OS", "appBuildVersion": "\(Int.random(in: 1..<99_999))", "deviceType": "Test device",
                                   "exceptionType": 1, "signal": 11, "terminationReason": "Namespace SIGNAL, Code 11"],
            "callStackTree": ["callStacks": [["threadAttributed": true, "callStackRootFrames": [[
                "binaryName": "MeshLive", "offsetIntoBinaryTextSegment": 4660, "binaryUUID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"]]]]],
        ]]]
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        return CrashReport.reports(fromPayloadJSON: data).first ?? "MeshLive crash report"
    }
    #endif
}

/// "MeshLive closed unexpectedly": the exact report, Share (system share sheet), Not now, Don't ask again.
struct CrashReportSheet: View {
    @ObservedObject var reports = CrashReports.shared
    let text: String
    /// After Share the sheet stays until Done, so the system share sheet it opened is not torn down.
    @State private var sharing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(CrashReport.promptTitle).font(.title2.weight(.bold)).foregroundStyle(Palette.ink)
            Text(CrashReport.promptText).font(.body).foregroundStyle(Palette.dimInk).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(text).font(.footnote.monospaced()).foregroundStyle(Palette.ink).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .frame(maxHeight: 260)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityIdentifier("crash-report-text")
            ShareLink(item: text, subject: Text("MeshLive crash report")) {
                Text("Share").font(.body.weight(.semibold)).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).padding(.vertical, 14).background(Color.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { sharing = true })
            CapsuleButton(title: sharing ? "Done" : "Not now", kind: .dark) { reports.answered(shared: sharing) }
            Button("Don't ask again") { reports.disable() }
                .font(.subheadline).foregroundStyle(Palette.dimInk).frame(maxWidth: .infinity)
                .buttonStyle(.plain)
        }
        .padding(20)
        .frame(minWidth: AppPlatform.isMac ? 480 : nil)
        .background(Palette.ground.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

extension View {
    /// Shows the crash report question while one is waiting.
    func crashReportPrompt() -> some View { modifier(CrashReportPrompt()) }
}

private struct CrashReportPrompt: ViewModifier {
    @ObservedObject var reports = CrashReports.shared
    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { reports.pending != nil }, set: { _ in })) {
            if let text = reports.pending { CrashReportSheet(text: text).interactiveDismissDisabled() }
        }
    }
}
