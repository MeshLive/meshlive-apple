// swift-tools-version: 5.9
import PackageDescription
import Foundation

// libvpx (VP9) is built locally by Scripts/prepare-libvpx.sh into an ignored XCFramework. Without it the
// C bridge compiles explicit "not linked" stubs, so the protocol core still builds and tests.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let hasVPX = FileManager.default.fileExists(atPath: root + "/Vendor/VPX.xcframework/Info.plist")
var vpxDependencies: [Target.Dependency] = hasVPX ? ["VPX"] : []
var targets: [Target] = [
    .target(name: "NearbyCore"),
    .target(name: "CNearbyVPX", dependencies: vpxDependencies),
    .target(name: "NearbyMedia", dependencies: ["NearbyCore", "CNearbyVPX"]),
    // Experimental, default off: the original standalone Noise XX v1 protocol (iPhone-to-iPhone only).
    .target(name: "NearbyV1Experimental", dependencies: ["NearbyCore"]),
    // MeshPeer: a macOS CoreBluetooth test peer from the protocol core and the app's radio files (Peer/README.md).
    // The Info.plist is embedded in the binary so macOS can show the Bluetooth permission prompt.
    .executableTarget(name: "MeshPeer", dependencies: ["NearbyCore"], path: ".",
                      sources: ["Peer/main.swift", "Peer/PeerLog.swift", "App/Transport/MeshRadio.swift", "App/Transport/MeshLinks.swift"],
                      linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", root + "/Peer/Info.plist"])]),
    .testTarget(name: "NearbyCoreTests", dependencies: ["NearbyCore"], resources: [.copy("Fixtures")]),
    .testTarget(name: "NearbyMediaTests", dependencies: ["NearbyCore", "NearbyMedia"], resources: [.copy("Fixtures")]),
    .testTarget(name: "NearbyV1ExperimentalTests", dependencies: ["NearbyCore", "NearbyV1Experimental"], resources: [.copy("Fixtures")]),
]
if hasVPX { targets.append(.binaryTarget(name: "VPX", path: "Vendor/VPX.xcframework")) }

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
