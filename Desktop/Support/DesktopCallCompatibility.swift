import Foundation
import NearbyCore

/// Mac call policy for rotating offers and BMH3. Since 2026-11-04 rotating IDs, hidden identities and pseudonyms are
/// always on (product decision, as Android), which already accepts and calls rotating offers; `enabled` ("Android
/// compatibility") has no Settings row and is only a DEBUG control arm for runs that turn the trio off. Receiving a
/// rotating offer is independent of advertising one; all authentication and advert-opening checks stay in the
/// existing call engines.
struct DesktopCallCompatibility {
    var enabled = false
    var rotatingIds = false
    var hiddenIdentities = false
    var pseudonyms = false

    var acceptsRotating: Bool { enabled || rotatingIds }

    func rotatingOptions(selected: DiscoveryAnnouncement) -> RotatingCallOptions? {
        guard rotatingIds || (enabled && selected.rotating) else { return nil }
        return RotatingCallOptions(selected: selected)
    }

    func bmh3Options(selected: DiscoveryAnnouncement?, pins: Bmh3Pins? = nil) -> Bmh3CallOptions? {
        guard enabled || hiddenIdentities else { return nil }
        // A default Android responder presents a pseudonym and refuses a real-key caller. Use the
        // existing per-attempt throwaway for a selected rotating offer, independent of our own advert.
        let rotatingCaller = enabled && selected?.rotating == true
        return Bmh3CallOptions(pseudonyms: rotatingCaller || (hiddenIdentities && pseudonyms && rotatingIds),
                               selected: selected, pins: pins)
    }
}
