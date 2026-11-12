import Foundation

/// "You appear as mild bream · changes every 15 min" (Android OwnNearbyName): what a nearby device that has not added
/// you shows for this device right now, so two people meeting can match up. Shown on Calls › Nearby, under
/// Settings › Your name while no name is set, on the incoming call screen and on Add contact.
///
/// The name is the generated name of this device's current rotating call ID (the value a scanner computes from the same
/// public bytes), so it changes at every rotating-ID boundary. With rotating IDs off, people who have not added you see
/// "Someone nearby", which does not change; with generated names off, rotating rows read "Nearby phone".
public enum OwnNearbyName {
    public struct Shown: Equatable {
        public let name: String
        public let rotates: Bool
        public init(name: String, rotates: Bool) { self.name = name; self.rotates = rotates }
    }

    public static let someoneNearby = "Someone nearby"
    public static let nearbyPhone = "Nearby phone"
    public static let infoTitle = "Your name nearby"
    public static let info = "To keep you private, your device shows people nearby a random ID that changes every 15 minutes, and they see a made-up name made from it. Your real name, if you set one, is only sent encrypted to the people you choose (Settings › Your name)."

    /// nil while this device is not reachable for calls, or before its rotating ID with a generated name is on air.
    public static func shown(reachableForCalls: Bool, rotatingOn: Bool, generatedNamesOn: Bool, generatedName: String?) -> Shown? {
        guard reachableForCalls else { return nil }
        if !rotatingOn { return Shown(name: someoneNearby, rotates: false) }
        if !generatedNamesOn { return Shown(name: nearbyPhone, rotates: false) }
        return generatedName.map { Shown(name: $0, rotates: true) }
    }

    public static func line(_ shown: Shown) -> String {
        shown.rotates ? "You appear as \(shown.name) \u{00B7} changes every 15 min" : "You appear as \(shown.name)"
    }
}

/// Settings › Your name (Android 2026-11-04, "a rejected name keeps the current name"): what applying the typed text
/// does. An empty field clears the name; a name the label rules accept is saved in its canonical form, the same text
/// a call carries; a rejected name keeps the current name, so a typo never erases or silently replaces it.
public enum OwnNameEdit: Equatable {
    case save(String)
    case clear
    case keep(reason: String)

    public static func outcome(typed: String) -> OwnNameEdit {
        if LabelText.collapseWhitespace(typed).isEmpty { return .clear }
        switch LabelText.normalize(.personName, typed) {
        case .success(let name): return .save(name)
        case .failure(let rejected): return .keep(reason: rejected.reason)
        }
    }

    /// The name to store when the typed text is applied while `current` is stored.
    public func resolved(current: String) -> String {
        switch self {
        case .save(let name): return name
        case .clear: return ""
        case .keep: return current
        }
    }

    /// Why the typed text cannot be used, or nil when applying it is fine.
    public var rejection: String? {
        if case .keep(let reason) = self { return reason }
        return nil
    }
}
