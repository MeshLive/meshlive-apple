import Foundation

/// B1F step 2: the state one decoder generation carries across its serial queue. Retirement is set by the owner (main)
/// and read inside queued decode blocks, so a key frame queued before a rebuild never creates a new VideoToolbox session
/// on the retired decoder. The invalidate block is enqueued on the same serial queue, behind any in-flight decode.
public final class DecoderRetirement {
    private let lock = NSLock()
    private var retired = false

    public init() {}

    public func retire() { lock.withLock { retired = true } }

    public var isRetired: Bool { lock.withLock { retired } }
}
