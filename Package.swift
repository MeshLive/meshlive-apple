// swift-tools-version: 5.9
import PackageDescription
import Foundation

// libvpx (VP9) is built locally by Scripts/prepare-libvpx.sh into an ignored XCFramework. Without it the
// C bridge compiles explicit "not linked" stubs, so the protocol core still builds and tests.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vpxPath = FileManager.default.fileExists(atPath: root + "/Vendor/VPX.xcframework/Info.plist")
    ? "Vendor/VPX.xcframework" : "Vendor/VPX-macos.xcframework"
let hasVPX = FileManager.default.fileExists(atPath: root + "/" + vpxPath + "/Info.plist")
var vpxDependencies: [Target.Dependency] = hasVPX ? ["VPX"] : []
var peerDependencies: [Target.Dependency] = ["NearbyCore"]
#if os(macOS)
peerDependencies.append("DesktopSupport")
#endif
var targets: [Target] = [
    .target(name: "NearbyCore"),
    .target(name: "CNearbyVPX", dependencies: vpxDependencies),
    .target(name: "NearbyMedia", dependencies: ["NearbyCore", "CNearbyVPX"]),
    // Experimental, default off: the original standalone Noise XX v1 protocol (iPhone-to-iPhone only).
    .target(name: "NearbyV1Experimental", dependencies: ["NearbyCore"]),
    // MeshPeer: a macOS CoreBluetooth test peer from the protocol core and the app's radio files (Peer/README.md).
    // The Info.plist is embedded in the binary so macOS can show the Bluetooth permission prompt.
    .executableTarget(name: "MeshPeer", dependencies: peerDependencies, path: ".", exclude: ["Desktop"],
                      sources: ["Peer/main.swift", "Peer/PeerLog.swift", "App/Transport/MeshRadio.swift", "App/Transport/MeshLinks.swift"],
                      linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", root + "/Peer/Info.plist"])]),
    .testTarget(name: "NearbyCoreTests", dependencies: ["NearbyCore"], resources: [.copy("Fixtures")]),
    .testTarget(name: "NearbyMediaTests", dependencies: ["NearbyCore", "NearbyMedia"], resources: [.copy("Fixtures")]),
    .testTarget(name: "NearbyV1ExperimentalTests", dependencies: ["NearbyCore", "NearbyV1Experimental"], resources: [.copy("Fixtures")]),
]
#if os(macOS)
// Native app policy only. The Xcode Mac target compiles the same source from Desktop/Support.
targets += [
    .target(name: "DesktopSupport", dependencies: ["NearbyCore"], path: "Desktop/Support", resources: [.copy("Names")]),
    .testTarget(name: "DesktopSupportTests", dependencies: ["DesktopSupport", "NearbyCore"]),
    // Exercise the real native connection driver against an in-memory pipe, without opening Bluetooth.
    .testTarget(name: "DesktopTransportTests", dependencies: ["MeshPeer", "NearbyCore"]),
]
#endif
if hasVPX { targets.append(.binaryTarget(name: "VPX", path: vpxPath)) }

let package = Package(
    name: "NearbyIntercom",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "NearbyCore", targets: ["NearbyCore"]),
        .library(name: "NearbyMedia", targets: ["NearbyMedia"]),
        .library(name: "NearbyV1Experimental", targets: ["NearbyV1Experimental"]),
    ],
    targets: targets
)
