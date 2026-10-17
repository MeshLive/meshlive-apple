import SwiftUI
import AVFoundation
import CoreImage.CIFilterBuiltins
import NearbyCore

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
                if let text = model.myQrText(), let image = qrImage(text) {
                    Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
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
        .navigationBarTitleDisplayMode(.large)
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
