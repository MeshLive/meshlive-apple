import Foundation
import NearbyCore

@main enum CodecDiagnostic {
    static func main() {
        let video = PatternVideo()
        var failed = false
        var latest = VideoMetrics()
        video.onFailure = { print("FAIL: \($0)"); failed = true }
        video.onMetrics = { metrics in
            latest = metrics
            if metrics.elapsed > 0 {
                let data = try! JSONEncoder().encode(metrics)
                print(String(decoding: data, as: UTF8.self))
            }
        }
        video.start(loopback: true, frames: 30) {
            guard !failed, latest.encodedFrames == 30, latest.decodedFrames == 30,
                  latest.encodedBytes > 0, latest.peakAccessUnit > 0, latest.peakAccessUnit <= 24_000 else {
                print("FAIL: did not encode/decode all 30 bounded pattern frames"); exit(1)
            }
            print("PASS: 30 generated H.264 frames encoded and decoded (Mac only); no device-video claim"); exit(0)
        }
        dispatchMain()
    }
}
