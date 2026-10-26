import Foundation

/// The camera's first-frame check (Android `test_drop_leading_blank_frames`, 2026-10-20): some cameras deliver a few
/// exactly black buffers before the first real picture (the S22 delivered 4 in every run), so a viewer's or callee's
/// first picture was black. The check always measures and logs how many leading frames were blank; dropping them is an
/// Experimental, default-off choice (`-dropLeadingBlankFrames YES`). At most 15 frames or 1 s after the first are
/// dropped, and nothing after the first real frame.
public struct LeadingBlankFrames {
    public static let maxFrames = 15
    public static let maxSeconds: TimeInterval = 1

    public let dropBlank: Bool
    public private(set) var blankFrames = 0
    public private(set) var droppedFrames = 0
    /// True once the first real frame arrived (or the bound passed): the check is over.
    public private(set) var done = false
    public private(set) var firstFrameAt: TimeInterval?
    public private(set) var firstRealAt: TimeInterval?

    public init(dropBlank: Bool) { self.dropBlank = dropBlank }

    /// Android's rule: mean luma below 1 and both chroma means within 1 of 128 (sampled on a sparse grid).
    public static func isBlank(_ picture: I420Picture) -> Bool {
        func mean(_ plane: [UInt8], _ width: Int, _ height: Int) -> Double {
            guard width > 0, height > 0 else { return 0 }
            var sum = 0, count = 0
            for row in stride(from: 0, to: height, by: 8) {
                for col in stride(from: 0, to: width, by: 8) { sum += Int(plane[row * width + col]); count += 1 }
            }
            return count == 0 ? 0 : Double(sum) / Double(count)
        }
        let luma = mean(picture.y, picture.width, picture.height)
        let u = mean(picture.u, picture.chromaWidth, picture.chromaHeight), v = mean(picture.v, picture.chromaWidth, picture.chromaHeight)
        return luma < 1 && abs(u - 128) <= 1 && abs(v - 128) <= 1
    }

    /// True when this frame is to be dropped (only while dropping is on and within the bound).
    public mutating func shouldDrop(_ picture: I420Picture, now: TimeInterval) -> Bool {
        guard !done else { return false }
        if firstFrameAt == nil { firstFrameAt = now }
        guard Self.isBlank(picture) else { done = true; firstRealAt = now; return false }
        blankFrames += 1
        let withinBound = droppedFrames < Self.maxFrames && now - (firstFrameAt ?? now) <= Self.maxSeconds
        guard dropBlank, withinBound else {
            if dropBlank { done = true }        // past the bound: send from here on
            return false
        }
        droppedFrames += 1
        return true
    }
}
