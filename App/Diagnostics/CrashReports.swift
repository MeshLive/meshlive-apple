import Foundation
import MetricKit
import CryptoKit
import SwiftUI
import NearbyCore
import CoreBluetooth
import CoreMedia
import VideoToolbox
#if canImport(NearbyMedia)
import NearbyMedia
#endif

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

    /// The newest kept report of the last 7 days (Android Export diagnostics' last_crash), or nil.
    var newestReport: String? {
        guard enabled else { return nil }
        return files().last.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
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
        #if DEBUG
        // Scripted DEBUG runs (-Nearby* launch arguments) never pop the sheet over the scenario; the report stays kept
        // and is offered on the next normal launch. The crash-report fixture run (-NearbyCrashReportFixture) is the
        // sheet's own UI test, so it is shown there.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(where: { $0.hasPrefix("-Nearby") }), !arguments.contains("-NearbyCrashReportFixture") { pending = nil; return }
        #endif
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
            Text(CrashReport.promptText(mac: AppPlatform.isMac)).font(.body).foregroundStyle(Palette.dimInk).fixedSize(horizontal: false, vertical: true)
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
    /// Shows the crash report question while one is waiting and onboarding/terms are not covering the app.
    func crashReportPrompt(suppressed: Bool = false) -> some View {
        modifier(CrashReportPrompt(suppressed: suppressed))
    }
}

private struct CrashReportPrompt: ViewModifier {
    @ObservedObject var reports = CrashReports.shared
    let suppressed: Bool
    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { reports.pending != nil && !suppressed }, set: { _ in })) {
            if !suppressed, let text = reports.pending { CrashReportSheet(text: text).interactiveDismissDisabled() }
        }
    }
}

/// The codec rows of About and Manual video and the export's `codecs:` line (`CodecRows`): what this build links, what the
/// OS offers and, for HEVC and H.264, what their Experimental masters and probes allow (AB5 R7). With both masters off,
/// every text is the VP9/AV1 text of before. A master on can run the encoder probe here if the launch probe has not
/// finished yet (DEBUG builds only).
enum CodecSummary {
    static var rows: CodecRows {
        func platform(_ probed: Bool, _ type: CMVideoCodecType) -> CodecRows.Decoder {
            probed ? (VTIsHardwareDecodeSupported(type) ? .hardware : .software) : .none
        }
        return CodecRows(vp9: VideoDecoderSupport.videoToolboxVP9 ? .hardware : VP9Encoder.isAvailable ? .software : .none,
                         av1Hardware: VideoDecoderSupport.videoToolboxAV1,
                         hevc: platform(StreamProtocol.hevcEnabled && VideoDecoderSupport.videoToolboxHEVC, kCMVideoCodecType_HEVC),
                         h264: platform(StreamProtocol.h264Enabled && VideoDecoderSupport.videoToolboxH264, kCMVideoCodecType_H264),
                         vp9Encoder: VP9Encoder.isAvailable,
                         hevcEncoder: StreamProtocol.hevcEnabled && HardwareEncoderSupport.isEligible(.hevc),
                         h264Encoder: StreamProtocol.h264Enabled && HardwareEncoderSupport.isEligible(.h264),
                         opus: CallAudio.opusAvailable)
    }
    static var decode: String { rows.decode }
    static var encode: String { rows.encode }
    static var voice: String { rows.voice }
}

/// Export diagnostics (Android Help and feedback): the typed facts of this build and device, built into the text by
/// `DiagnosticsReport` (NearbyCore checks every value). Nothing from `AppLog`, the contacts, the call history, the
/// identity or the radio's peers is read here.
enum DiagnosticsExport {
    static func text() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let version = os.patchVersion > 0 ? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)" : "\(os.majorVersion).\(os.minorVersion)"
        #if os(iOS)
        let extended: Bool? = CBCentralManager.supports(.extendedScanAndConnect)
        #else
        let extended: Bool? = nil
        #endif
        let facts = DiagnosticsReport.Facts(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "",
            appBuild: info["CFBundleVersion"] as? String ?? "",
            debugBuild: debug,
            sourceCommit: info["MeshLiveSourceCommit"] as? String,
            modelIdentifier: modelIdentifier,
            mac: AppPlatform.isMac,
            systemVersion: version,
            bluetoothPermission: MediaPermissions.bluetooth,
            extendedScanAndConnect: extended,
            codecs: CodecSummary.rows.export,
            lastCrash: CrashReports.shared.newestReport)
        return DiagnosticsReport.build(facts)
    }

    /// The hardware model identifier (`hw.machine` on the iPhone, `hw.model` on the Mac; a simulator reports the model
    /// it simulates). Never the user-given device name.
    static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty { return simulated }
        #if os(iOS)
        let key = "hw.machine"
        #else
        let key = "hw.model"
        #endif
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }
}
