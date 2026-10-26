import SwiftUI

/// macOS Dynamic Type does not scale text. Offer app-local content zoom, including controls and spacing.
struct DesktopReadingSize: ViewModifier {
    @AppStorage("desktopContentSize") private var size = 100
    private var scale: CGFloat { CGFloat([100, 115, 130].contains(size) ? size : 100) / 100 }
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .environment(\.dynamicTypeSize, size >= 130 ? .accessibility1 : .large)
                .frame(width: geometry.size.width / scale, height: geometry.size.height / scale)
                .scaleEffect(scale, anchor: .topLeading)
        }
        .frame(minWidth: 500, minHeight: 450)
    }
}

struct DesktopReadingSettings: View {
    @AppStorage("desktopContentSize") private var size = 100
    var body: some View {
        Card {
            Picker("Content size", selection: $size) {
                Text("Standard").tag(100)
                Text("Larger").tag(115)
                Text("Largest").tag(130)
            }
            .pickerStyle(.menu).padding(16).accessibilityIdentifier("desktop-content-size")
        }
        CardNote("Enlarges text, controls and spacing in MeshLive. Scroll to reach content that no longer fits in the window.")
    }
}
