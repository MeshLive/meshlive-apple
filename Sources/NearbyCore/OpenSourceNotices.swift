import Foundation

/// One component whose licence text ships in the app, shown under Settings > About this app > Open-source licences.
/// `resources` are file names at the app bundle root, read from the same repository files that THIRD_PARTY_NOTICES
/// links to. Test-only components are not listed.
public struct OpenSourceNotice: Equatable, Identifiable {
    public let id: String
    public let title: String
    public let version: String
    public let licence: String
    public let resources: [String]

    public init(id: String, title: String, version: String, licence: String, resources: [String]) {
        self.id = id
        self.title = title
        self.version = version
        self.licence = licence
        self.resources = resources
    }
}

public enum OpenSourceNotices {
    /// The components of THIRD_PARTY_NOTICES' "Linked into the apps" and "Data and ported algorithms" tables, in
    /// the order of that file: MeshLive itself first, then the linked libraries and the ported data.
    public static let entries: [OpenSourceNotice] = [
        OpenSourceNotice(id: "meshlive", title: "MeshLive", version: "", licence: "GNU GPL v3 or later",
                         resources: ["LICENSE", "LICENSE-EXCEPTION.md"]),
        OpenSourceNotice(id: "opus", title: "Opus", version: "1.6.1", licence: "BSD-3-Clause",
                         resources: ["OPUS-COPYING"]),
        OpenSourceNotice(id: "libvpx", title: "libvpx", version: "1.15.2", licence: "BSD-3-Clause",
                         resources: ["LIBVPX-LICENSE", "LIBVPX-PATENTS"]),
        OpenSourceNotice(id: "unicode", title: "Unicode Character Database", version: "15.0.0", licence: "Unicode License v3",
                         resources: ["UNICODE-LICENSE.txt"]),
        OpenSourceNotice(id: "webrtc", title: "WebRTC default bitrate limits", version: "", licence: "BSD-3-Clause",
                         resources: ["WEBRTC-LICENSE"]),
        OpenSourceNotice(id: "android-names", title: "MeshLive for Android name lists", version: "", licence: "GNU GPL v3 or later",
                         resources: ["LICENSE"]),
    ]
}
