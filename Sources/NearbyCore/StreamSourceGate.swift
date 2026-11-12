import Foundation

/// C1.1: which stream roles this build may use (Android `sourceRoles`). A release build watches only: no source, no
/// forwarder offer and no relay rows. A DEBUG build turns the roles back on with `-appleSourceRoles YES`, which
/// `ReleaseGates.sourceRoles` reads; the stored relay choice stays for the day the gate opens.
public struct StreamSourceGate: Equatable {
    public init(sourceRoles: Bool) { self.sourceRoles = sourceRoles }

    private let sourceRoles: Bool

    public var allowsGoLive: Bool { sourceRoles }
    public var allowsForwarding: Bool { sourceRoles }
    /// Go live button and menu item, relay rows.
    public var showsSourceControls: Bool { sourceRoles }

    public func effectiveRelayForOthers(requested: Bool) -> Bool { requested && sourceRoles }

    public var footerNotice: String? { sourceRoles ? nil : StreamSourceGate.laterNotice }

    public static let laterNotice = "Going live and passing streams on return in a later update."
}
