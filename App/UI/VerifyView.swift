import SwiftUI
import AVFoundation
import CoreImage.CIFilterBuiltins
import NearbyCore
#if os(macOS)
import AppKit
import Vision
#endif

/// "Add contact" (verify in person): your BVMID1 QR code and full ID, and scan theirs. The contact list is the Contacts tab.
struct VerifyView: View {
    @EnvironmentObject var model: AppModel
    @State private var scanning = false
    @State private var result: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                CardNote("Meet in person. Scan each other's code, or compare the safety code on both screens during a call. If they match, no one is in the middle.")
                    .padding(.bottom, 4)
                if let line = model.ownNearbyLine { OwnNearbyNameLine(text: line).padding(.horizontal, 6) }
                if let text = model.myQrText(), let image = qrImage(text) {
                    Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
                        .padding(14).background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .frame(maxWidth: 260).frame(maxWidth: .infinity)
                        .accessibilityLabel("QR code with your ID for the other person to scan")
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
                        Text(model.fingerprint?.grouped ?? "").font(.footnote.monospaced()).foregroundStyle(Palette.dimInk).textSelection(.enabled)
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 8)
                CapsuleButton(title: "Scan their code", systemImage: AppIcon.scan, kind: .white) { scanning = true }
                    .disabled(model.call != nil)
                    .padding(.top, 8)
                if let result { Text(result).font(.subheadline).foregroundStyle(Palette.ink) }
                CardNote("Call or watch them first, so this phone has checked their key; then scan.")
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
        }
        .background(Palette.ground.ignoresSafeArea())
        .navigationTitle("Add contact")
        .mobileNavigationTitle(inline: false)
        .sheet(isPresented: $scanning) {
            QRScannerView { text in
                scanning = false
                do {
                    let payload = try IdentityQrCodec.parse(text)
                    try model.markVerified(scanned: payload)
                    result = "\(payload.displayName) is now verified."
                } catch let error as ProtocolError where error == .state("No authenticated session with this peer") {
                    result = "Connect to this person first (call or stream), then scan again."
                } catch {
                    result = "Not verified: \(error)"
                }
            }
        }
    }

    private func qrImage(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return cg
    }
}

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
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: context.coordinator.session)
        preview.videoGravity = .resizeAspectFill
        view.layer = preview
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
