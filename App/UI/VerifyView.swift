import SwiftUI
import AVFoundation
import CoreImage.CIFilterBuiltins
import NearbyCore

/// "Verify a contact": your BVMID1 QR code and full ID, scan theirs, and the verified-contact list.
struct VerifyView: View {
    @EnvironmentObject var model: AppModel
    @State private var scanning = false
    @State private var result: String?

    var body: some View {
        List {
            Section {
                Text("Meet in person. Scan each other's code, or compare the safety code on both screens during a call. If they match, no one is in the middle.")
                    .font(Typo.secondary)
            }
            Section("Your code") {
                if let text = model.myQrText(), let image = qrImage(text) {
                    Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 260).frame(maxWidth: .infinity)
                        .accessibilityLabel("QR code with your ID for the other person to scan")
                }
                LabeledContent("Your ID") { Text(model.handle).font(Typo.code) }
            }
            Section("Full fingerprint") {
                Text(model.fingerprint?.grouped ?? "").font(.footnote.monospaced()).textSelection(.enabled)
            }
            Section {
                PrimaryButton(title: "Scan their code", systemImage: AppIcon.scan) { scanning = true }
                    .disabled(model.call != nil)
                if let result { Text(result).font(.footnote).foregroundStyle(.secondary) }
            } footer: { FooterText("Call or watch them first, so this phone has checked their key; then scan.") }
            if let unreadable = model.contactsUnreadable {
                Section("Verified contacts unavailable") {
                    Text("The saved list could not be opened (\(unreadable)). Everyone counts as unverified until you reset it.").font(.footnote)
                    Button("Reset verified contacts", role: .destructive) { model.resetContacts() }
                }
            }
            Section("Verified contacts") {
                if model.contacts.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                ForEach(model.contacts, id: \.fingerprintHex) { contact in
                    VStack(alignment: .leading) {
                        Text(contact.displayName).font(Typo.rowTitle)
                        Text("ID \(IdentityHandle.handle(prefix: Data(hex: contact.nodePrefixHex) ?? Data()) ?? ""), checked by \(contact.method == "qr" ? "QR code" : "safety code")")
                            .font(Typo.caption).foregroundStyle(Palette.dimInk)
                    }
                    .swipeActions { Button("Forget", role: .destructive) { model.forget(contact) } }
                }
            }
        }
        .monoList()
        .navigationTitle("Verify a contact")
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

    private func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

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
