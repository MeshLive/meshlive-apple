import Foundation

/// How far the other phone turns this phone's call picture (clockwise, `MediaPacket.displayRotation`) as the iPhone
/// turns. The capture connection keeps frames in the phone's portrait orientation, so a phone held sideways sends
/// a sideways scene; the rotation packet (BME1 display rotation, which Android sends when its camera changes) lets
/// the receiver show it upright. The value is the phone's clockwise turn from portrait for both cameras: the front
/// camera's frames are mirrored, which cancels the opposite turn an unmirrored front sensor would need (Android's
/// `relativeRotationDegrees`: back `sensor + turn`, front `sensor - turn`).
public struct CallDisplayRotation {
    public enum Orientation: Equatable { case portrait, portraitUpsideDown, landscapeLeft, landscapeRight, faceUpOrDownOrUnknown }

    /// What the other phone was last told (the call header says 0).
    public private(set) var sent = 0
    private var current = 0

    public init() {}

    /// Clockwise degrees for a device orientation; nil when flat or unknown (the last upright orientation stays).
    /// `landscapeRight` is the phone turned clockwise (top to the right), `landscapeLeft` counter-clockwise.
    public static func degrees(_ orientation: Orientation) -> Int? {
        switch orientation {
        case .portrait: return 0
        case .landscapeRight: return 90
        case .portraitUpsideDown: return 180
        case .landscapeLeft: return 270
        case .faceUpOrDownOrUnknown: return nil
        }
    }

    /// The phone turned. Returns the rotation to send when `sending` and it changed what the other phone shows.
    public mutating func deviceTurned(_ orientation: Orientation, sending: Bool) -> Int? {
        if let degrees = Self.degrees(orientation) { current = degrees }
        return pending(sending: sending)
    }

    /// The rotation to send now (for example when the camera turns on), or nil when the other phone already has it.
    public mutating func pending(sending: Bool) -> Int? {
        guard sending, current != sent else { return nil }
        sent = current
        return current
    }
}
