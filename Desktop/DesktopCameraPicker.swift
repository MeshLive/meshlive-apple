import SwiftUI
import AVFoundation

enum DesktopCameraDevices {
    static let selectionChanged = Notification.Name("MeshLiveDesktopCameraSelectionChanged")
    static var available: [AVCaptureDevice] {
        guard !DesktopPreview.enabled else { return [] }
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified)
            .devices.filter { $0.deviceType != .continuityCamera }
    }
    static func selected() -> AVCaptureDevice? {
        let devices = available
        let preferred = DesktopPreview.preferences.string(forKey: "desktopCameraID") ?? ""
        let builtIn = devices.first { $0.deviceType == .builtInWideAngleCamera }?.uniqueID
        let id = CameraSelection.selectedID(preferred: preferred, available: devices.map(\.uniqueID), defaultID: builtIn)
        return devices.first { $0.uniqueID == id }
    }

    /// Flip on the Mac (Android Flip; a Mac has no front and back lens): the next available camera becomes the selected
    /// one, and a running capture follows it (`selectionChanged`). Nothing happens with fewer than two cameras.
    static func selectNext() {
        let devices = available
        guard devices.count > 1 else { return }
        let current = selected()?.uniqueID
        let index = devices.firstIndex { $0.uniqueID == current } ?? -1
        DesktopPreview.preferences.set(devices[(index + 1) % devices.count].uniqueID, forKey: "desktopCameraID")
        NotificationCenter.default.post(name: selectionChanged, object: nil)
    }
}

struct DesktopCameraPicker: View {
    @AppStorage("desktopCameraID") private var selected = ""
    @State private var devices: [AVCaptureDevice] = []
    var body: some View {
        Picker("Camera", selection: $selected) {
            Text("Automatic").tag("")
            ForEach(devices, id: \.uniqueID) { device in Text(device.localizedName).tag(device.uniqueID) }
            if !selected.isEmpty && !devices.contains(where: { $0.uniqueID == selected }) {
                Text("Selected camera unavailable").tag(selected)
            }
        }
        .pickerStyle(.menu).accessibilityIdentifier("desktop-camera")
        .onAppear { devices = DesktopCameraDevices.available }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in devices = DesktopCameraDevices.available }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in devices = DesktopCameraDevices.available }
        .onChange(of: selected) { _, _ in NotificationCenter.default.post(name: DesktopCameraDevices.selectionChanged, object: nil) }
    }
}

