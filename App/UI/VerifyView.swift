import SwiftUI
import AVFoundation
import CoreImage.CIFilterBuiltins
import NearbyCore
#if os(macOS)
import AppKit
import Vision
#else
import UIKit
#endif

/// "Add contact" (Android VerifyContactActivity): **Scan their code | Show my code**. With BVMID2 the code works once and for
/// five minutes, is hidden while the screen is recorded or mirrored (iPhone) and kept out of screen sharing (Mac), and a
/// scan asks "Is this <name>'s screen?" before the shield. Without rotating IDs or hidden identities the static BVMID1 code
/// and the scan-after-a-call flow remain. The contact list is the Contacts tab.
struct VerifyView: View {
    @EnvironmentObject var model: AppModel
    var showCode = false
    var body: some View { VerifyPage(meet: model.meet, showCode: showCode) }
}

private struct VerifyPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var meet: MeetController
    @Environment(\.scenePhase) private var scenePhase
    @State private var showCode: Bool
    @State private var scanning = false
    @State private var camera = QrScannerCamera.unknown
    @State private var contactName = ""

    init(meet: MeetController, showCode: Bool) {
        self.meet = meet
        _showCode = State(initialValue: showCode)
    }

    var body: some View {
        content
            .onAppear { meet.beginVisit(); meet.setShowingCode(showCode); refreshCapture(); refreshCamera() }
            .onDisappear { meet.endVisit() }
            .onChange(of: showCode) { meet.setShowingCode($0) }
            .onChange(of: scenePhase) { phase in
                // Leaving the app kills the code (Android: screen off, app backgrounded); coming back is a new visit.
                if phase == .active { meet.beginVisit(); meet.setShowingCode(showCode); refreshCapture(); refreshCamera() }
                else if phase == .background { meet.endVisit() }
            }
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in refreshCapture() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in meet.screenshotTaken() }
            #endif
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                #if os(macOS)
                PageHeader(title: "Add contact")
                #endif
                CardNote("Scan each other's codes in person to add a contact. During a call, you can also compare safety codes to confirm the connection.")
                    .padding(.bottom, 4)
                SegmentPair(first: "Scan their code", second: "Show my code", secondSelected: $showCode)
                if let status = meet.status, !(showCode && status == MeetController.gettingReadyText && meet.codeText != nil) {
                    Text(status).font(.subheadline).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("verify-status")
                }
                if meet.callNowPeer != nil {
                    // Design QL revision 2: an ordinary Contacts call for 60 s after the phones learnt to recognise each
                    // other; it waits while a verification connection is still open.
                    CapsuleButton(title: "Call now", systemImage: "video", kind: .white) { meet.callNow() }
                        .disabled(model.call != nil || meet.scanSessionOpen)
                        .accessibilityIdentifier("verifyCallNow")
                }
                if showCode { codeGroup() } else { scanGroup() }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
        }
        .background(Palette.ground.ignoresSafeArea())
        .pageTitle("Add contact")
        #if os(macOS)
        // The picture of a live code is a secret: the window is left out of screen sharing and recording while it shows.
        .background(WindowSharingGuard(excluded: showCode && meet.codeText != nil))
        #endif
        .sheet(isPresented: $scanning) {
            scannerSheet()
        }
        // Design QL revision 2: with the recognition choice the confirmation is a sheet (an alert cannot hold a checkbox).
        // Dismissing it unanswered counts as No (Android: a cancelled dialog).
        .sheet(item: Binding(get: { meet.asksRecognition ? meet.confirmation : nil }, set: { _ in })) { pending in
            RecognitionConfirmation(confirmation: pending) { yes, recognise in meet.answer(pending, yes: yes, recognise: recognise) }
        }
        .alert(meet.confirmation.map { "Is this \($0.name)'s screen?" } ?? "", isPresented: Binding(
            // The buttons answer; the binding never does (its write can come before a button's action).
            get: { meet.confirmation != nil && !meet.asksRecognition }, set: { _ in })) {
            Button("Yes, verify") { if let pending = meet.confirmation { meet.answer(pending, yes: true) } }
            Button("No", role: .cancel) { if let pending = meet.confirmation { meet.answer(pending, yes: false) } }
        } message: {
            Text("You reached the phone with ID \(meet.confirmation?.handle ?? ""). Check that it is the screen of the person in front of you before you continue.")
        }
        .alert("Two phones used your code", isPresented: Binding(get: { meet.reuseAlert }, set: { meet.reuseAlert = $0 })) {
            Button("Close", role: .cancel) {}
        } message: {
            Text("The first one may not be the person in front of you. Start again with the new code.")
        }
        .alert("Save contact as", isPresented: Binding(get: { meet.saveContact != nil }, set: { _ in })) {
            TextField("Name", text: $contactName)
            Button("Save") { if let request = meet.saveContact { meet.save(request, name: contactName) } }
            Button("Skip", role: .cancel) { meet.saveContact = nil }
        } message: {
            Text("Pick a name that only you see. Leave it empty to keep their ID.")
        }
        .onChange(of: meet.saveContact) { request in contactName = request?.suggestion ?? "" }
    }

    @ViewBuilder private func codeGroup() -> some View {
        SectionLabel("Your code")
        if let line = model.ownNearbyLine { OwnNearbyNameLine(text: line).padding(.horizontal, 6) }
        if let text = meet.available ? meet.codeText : model.myQrText(), let image = qrImage(text) {
            Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
                .padding(14).background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: 260).frame(maxWidth: .infinity)
                .accessibilityElement()
                .accessibilityLabel("QR code with your ID for the other person to scan")
                .accessibilityIdentifier("verify-code")
        } else if meet.available, meet.captureHidden {
            CardNote("Your code is hidden while the screen is recorded or shared.")
        }
        Card {
            HStack {
                Text("Your ID").font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                Spacer()
                Text(model.handle).font(Typo.code).foregroundStyle(Palette.dimInk)
            }
            .padding(.horizontal, 16).frame(minHeight: 56)
            .accessibilityElement(children: .combine)
            CardDivider(inset: 16)
            VStack(alignment: .leading, spacing: 6) {
                Text("Full fingerprint").font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                Text(model.fingerprint?.grouped ?? "Your ID is created the first time you use Bluetooth.")
                    .font(.footnote.monospaced()).foregroundStyle(Palette.dimInk).textSelection(.enabled)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 8)
    }

    @ViewBuilder private func scanGroup() -> some View {
        CapsuleButton(title: "Scan their code", systemImage: AppIcon.scan, kind: .white) {
            if QrScannerPermission.gate(camera) == .request {
                MediaPermissions.requestCamera { _ in
                    refreshCamera()
                    scanning = true
                }
            } else {
                scanning = true
            }
        }
        .disabled(model.call != nil || meet.scanning)
        .accessibilityIdentifier("verifyScanButton")
        .padding(.top, 8)
        if model.call != nil {
            CardNote("The camera is in use by your call. Compare the safety code above instead, or scan their code from Contacts \u{203A} Add contact right after the call.")
        } else if !meet.available {
            CardNote("Call or watch them first, so this phone has checked their key; then scan.")
        }
    }

    /// The scanner while allowed; otherwise one honest state with no black view behind a blocked camera.
    @ViewBuilder private func scannerSheet() -> some View {
        ZStack(alignment: .bottom) {
            if QrScannerPermission.gate(camera) == .scan {
                QRScannerView { text in
                    scanning = false
                    meet.scanned(text)
                }
                Text(QrScannerPermission.prompt)
                    .font(.subheadline).foregroundStyle(.white).multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, 32)
                    .accessibilityIdentifier("verifyScanPrompt")
            } else {
                scannerState(camera, action: scannerAction,
                             perform: scannerAction == nil ? nil : { AppPlatform.openSettings() })
            }
        }
        #if os(macOS)
        // A Mac sheet takes its content's size and the camera view has none, so the scanner was a thin strip at the top
        // left (device test 2026-11-12): give it a real camera-sized frame.
        .frame(width: 520, height: 400)
        #endif
    }

    /// One state for the blocked sheet: what is wrong, the one action when iOS or the Mac can change it, and Close.
    @ViewBuilder private func scannerState(_ camera: QrScannerCamera, action: String?, perform: (() -> Void)?) -> some View {
        VStack(spacing: 20) {
            Text(QrScannerPermission.message(camera, mac: isMac))
                .font(.body).foregroundStyle(Palette.ink).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("verifyCameraState")
            if let action, let perform {
                CapsuleButton(title: action, kind: .white) { perform() }
                    .accessibilityIdentifier("verifyCameraAction")
            }
            CapsuleButton(title: "Close", kind: .dark) { scanning = false }
                .accessibilityIdentifier("verifyCameraClose")
        }
        .padding(24)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private var scannerAction: String? {
        if case .blocked(opensSettings: true) = QrScannerPermission.gate(camera) { return "Open settings" }
        return nil
    }

    private var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    private func refreshCamera() {
        #if DEBUG
        if let forced = RootView.debugArgument("-NearbyFixtureCameraPermission").flatMap(QrScannerCamera.init(fixture:)) {
            camera = forced
            return
        }
        #endif
        camera = MediaPermissions.cameraPermission
    }

    private func refreshCapture() {
        #if os(iOS)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var captured = scene?.screen.isCaptured ?? false
        if #available(iOS 17.0, *), let scene { captured = captured || scene.traitCollection.sceneCaptureState == .active }
        meet.setCaptured(captured)
        #endif
    }

    private func qrImage(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return cg
    }
}

/// "Is this <name>'s screen?" with Android's recognition checkbox (Design QL revision 2, `ql_consent_checkbox`, checked
/// by default, Q-QL2a) and its line. The answer is given only by the buttons.
private struct RecognitionConfirmation: View {
    let confirmation: MeetController.Confirmation
    let answer: (_ yes: Bool, _ recognise: Bool) -> Void
    @State private var recognise = true
    @State private var answered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Is this \(confirmation.name)'s screen?").font(.title3.weight(.semibold)).foregroundStyle(Palette.ink)
            Text("You reached the phone with ID \(confirmation.handle). Check that it is the screen of the person in front of you before you continue.")
                .font(.subheadline).foregroundStyle(Palette.dimInk).fixedSize(horizontal: false, vertical: true)
            Button { recognise.toggle() } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: recognise ? "checkmark.square.fill" : "square").font(.title3)
                        .foregroundStyle(recognise ? Color.white : Palette.dimInk).accessibilityHidden(true)
                    Text("Let \(confirmation.name)'s phone recognise yours nearby").font(.body).foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Let \(confirmation.name)'s phone recognise yours nearby")
            .accessibilityValue(recognise ? "On" : "Off")
            .accessibilityAddTraits(recognise ? [.isSelected] : [])
            .accessibilityIdentifier("qlConsentCheckbox")
            Text("You can then call each other from Contacts. Turn off to stay unrecognised; you can still call from Nearby.")
                .font(.footnote).foregroundStyle(Palette.dimInk).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                CapsuleButton(title: "No", kind: .dark) { answered = true; answer(false, recognise) }.accessibilityIdentifier("qlConfirmNo")
                CapsuleButton(title: "Yes, verify", kind: .white) { answered = true; answer(true, recognise) }.accessibilityIdentifier("qlConfirmYes")
            }
        }
        .padding(24)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.ground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        // Dismissed without an answer (swipe, Escape): No for THIS confirmation, as Android's cancelled dialog.
        .onDisappear { if !answered { answered = true; answer(false, recognise) } }
    }
}

/// Android's two-segment control ("Scan their code" | "Show my code"): white for the chosen segment, dark otherwise.
struct SegmentPair: View {
    let first: String
    let second: String
    @Binding var secondSelected: Bool
    var body: some View {
        HStack(spacing: 4) {
            segment(first, selected: !secondSelected) { secondSelected = false }
            segment(second, selected: secondSelected) { secondSelected = true }
        }
        .padding(4)
        .background(Palette.chip, in: Capsule())
    }
    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(selected ? Color.black : Palette.ink)
                .frame(maxWidth: .infinity).frame(minHeight: 40)
                .background(selected ? Color.white : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

#if os(macOS)
/// Keeps its window out of screen sharing and screen recording while `excluded` (`NSWindow.sharingType = .none`), and
/// restores the window's earlier sharing type afterwards.
struct WindowSharingGuard: NSViewRepresentable {
    let excluded: Bool
    func makeNSView(context: Context) -> NSView { GuardView() }
    func updateNSView(_ view: NSView, context: Context) { (view as? GuardView)?.excluded = excluded }
    static func dismantleNSView(_ view: NSView, coordinator: ()) { (view as? GuardView)?.excluded = false }

    final class GuardView: NSView {
        private var saved: NSWindow.SharingType?
        var excluded = false { didSet { apply() } }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        private func apply() {
            guard let window else { return }
            if excluded {
                if saved == nil { saved = window.sharingType }
                window.sharingType = .none
            } else if let previous = saved {
                window.sharingType = previous
                saved = nil
            }
        }
    }
}
#endif

#if os(iOS)
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { let c = ScannerController(); c.onCode = onCode; return c }
    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var done = false
        override func viewDidLoad() {
            super.viewDidLoad(); view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.frame = view.bounds; preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }
        override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); session.stopRunning() }
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            done = true; session.stopRunning(); onCode?(code)
        }
    }
}

#else
struct QRScannerView: NSViewRepresentable {
    let onCode: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let preview = AVCaptureVideoPreviewLayer(session: context.coordinator.session)
        preview.videoGravity = .resizeAspectFill
        // Layer-hosting: the layer first, then wantsLayer, so AppKit sizes the preview with the view.
        view.layer = preview
        view.wantsLayer = true
        context.coordinator.start()
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

    final class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "io.github.meshlive.qr")
        private let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func start() {
            MediaPermissions.requestCamera { [weak self] allowed in
                guard allowed, let self else { return }
                self.queue.async {
                    guard let device = DesktopCameraDevices.selected(),
                          let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) else { return }
                    self.session.addInput(input)
                    let output = AVCaptureVideoDataOutput()
                    guard self.session.canAddOutput(output) else { return }
                    self.session.addOutput(output)
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    self.session.startRunning()
                }
            }
        }
        func stop() { queue.async { self.done = true; self.session.stopRunning() } }
        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard !done else { return }
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            try? VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up).perform([request])
            guard let text = request.results?.first?.payloadStringValue else { return }
            done = true
            DispatchQueue.main.async { self.onCode(text) }
        }
    }
}
#endif
