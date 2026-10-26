import Foundation

/// Scheduling policy for the native Mac connection driver. The driver owns and invalidates the timer.
public enum DesktopConnectionTimer {
    public static func schedule(every interval: TimeInterval = 0.1,
                                tick: @escaping (Timer) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true, block: tick)
        // Native menu, drag and modal loops must keep connection liveness running even
        // when both microphones are muted and media callbacks no longer drive the pump.
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
