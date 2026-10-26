import CoreGraphics

/// BTV3 display angles are clockwise. Native AppKit surfaces have an upward-positive y axis.
struct DesktopVideoLayout {
    let layerBounds: CGRect
    let position: CGPoint
    let transform: CGAffineTransform

    init(bounds: CGRect, clockwiseDegrees: Int) {
        let turned = clockwiseDegrees % 180 != 0
        layerBounds = CGRect(origin: .zero, size: turned
                             ? CGSize(width: bounds.height, height: bounds.width) : bounds.size)
        position = CGPoint(x: bounds.midX, y: bounds.midY)
        transform = CGAffineTransform(rotationAngle: -CGFloat(clockwiseDegrees) * .pi / 180)
    }
}
