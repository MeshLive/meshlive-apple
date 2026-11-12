import Foundation
import NearbyCore

/// B1.2 F4 (DEBUG only): names the main-queue task that was running when the main thread stalled, and reports while the
/// stall is still open. A utility timer pings the main queue every 0.25 s; `MainStallTracker` decides when a late answer
/// is a stall. Release builds compile `run` to a plain call and start no timer.
enum MainStall {
    #if DEBUG
    private static let lock = NSLock()
    private static var tracker = MainStallTracker()
    private static var timer: DispatchSourceTimer?
    #endif

    /// Idempotent: called once from `AppModel.start()` on every foreground.
    static func start() {
        #if DEBUG
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler {
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            tracker.pingSent(at: now)
            let open = tracker.poll(at: now)
            lock.unlock()
            if let open { logOpen(open) }
            DispatchQueue.main.async {
                let answered = ProcessInfo.processInfo.systemUptime
                lock.lock()
                let ended = tracker.pingAnswered(at: answered)
                lock.unlock()
                if let ended { logEnd(ended) }
            }
        }
        timer.resume()
        Self.timer = timer
        #endif
    }

    /// The bracket of `run` for a whole function body: `MainStall.enter("X"); defer { MainStall.exit() }`.
    static func enter(_ name: StaticString) {
        #if DEBUG
        let began = ProcessInfo.processInfo.systemUptime
        lock.lock(); tracker.enter("\(name)", at: began); lock.unlock()
        #endif
    }
    static func exit() {
        #if DEBUG
        let ended = ProcessInfo.processInfo.systemUptime
        lock.lock(); tracker.exit(at: ended); lock.unlock()
        #endif
    }

    /// Brackets a main-queue task. Names are static identifiers, never an ID, a person's name or a prefix.
    static func run<T>(_ name: StaticString, _ body: () -> T) -> T {
        #if DEBUG
        let began = ProcessInfo.processInfo.systemUptime
        lock.lock()
        tracker.enter("\(name)", at: began)
        lock.unlock()
        defer {
            let ended = ProcessInfo.processInfo.systemUptime
            lock.lock()
            tracker.exit(at: ended)
            lock.unlock()
        }
        #endif
        return body()
    }

    #if DEBUG
    private static func logOpen(_ open: MainStallTracker.Open) {
        var fields: [String: String] = ["stalledMs": "\(open.stalledMs)", "running": open.running.joined(separator: ">")]
        if let runningForMs = open.runningForMs { fields["runningForMs"] = "\(runningForMs)" }
        if let lastFinished = open.lastFinished { fields["lastFinished"] = lastFinished }
        if let lastFinishedAgoMs = open.lastFinishedAgoMs { fields["lastFinishedAgoMs"] = "\(lastFinishedAgoMs)" }
        AppLog.event("main_stall_open", fields)
    }

    private static func logEnd(_ ended: MainStallTracker.Ended) {
        AppLog.event("main_stall_end", ["totalMs": "\(ended.totalMs)", "longestMarked": ended.longestMarked ?? "none",
                                        "longestMarkedMs": "\(ended.longestMarkedMs)"])
    }
    #endif
}
