import Foundation
import VLCore

/// Logs how late the main thread answers, which is when sliders and taps stop following a finger.
/// A timer on its own queue posts one tiny block to the main queue four times a second and times
/// how long it waits. Only one is ever waiting, so a long stall counts once, and the main thread
/// does nothing but read the screen's name.
///
/// Added for the base iPhone 16, whose sliders lag: the viewfinder draws on the main thread, and
/// the summary says how long those draws hold it.
final class MainThreadWatch {
    /// Read on the main thread: which screen the stall happened on.
    var screen: () -> String = { "?" }
    /// Read on the watch's queue: how long the viewfinder's draws held the main thread.
    var drawSummary: () -> String? = { nil }

    /// A wait this long counts as late: about six frames at 60 Hz.
    static let lateMs = 100.0
    /// A wait this long is logged at once, up to `maxReportsPerMinute`.
    static let reportMs = 250.0
    static let maxReportsPerMinute = 10

    private let queue = DispatchQueue(label: "vibelog.main-watch", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var waiting = false
    private var late: [String: (count: Int, worst: Double)] = [:]
    private var reported = 0
    private var minuteStart = Date()

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 0.25, leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.ping() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Runs on `queue`.
    private func ping() {
        if Date().timeIntervalSince(minuteStart) >= 60 { summarize() }
        guard !waiting else { return }
        waiting = true
        let sent = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let milliseconds = (CFAbsoluteTimeGetCurrent() - sent) * 1000
            let screen = self.screen()
            self.queue.async { self.note(milliseconds, screen: screen) }
        }
    }

    /// Runs on `queue`.
    private func note(_ milliseconds: Double, screen: String) {
        waiting = false
        guard milliseconds >= Self.lateMs else { return }
        let seen = late[screen] ?? (0, 0)
        late[screen] = (seen.count + 1, max(seen.worst, milliseconds))
        if milliseconds >= Self.reportMs, reported < Self.maxReportsPerMinute {
            reported += 1
            Log.shared.warn("Main thread answered \(Int(milliseconds)) ms late on \(screen)")
        }
    }

    /// Runs on `queue`. Says nothing for a minute with no late answer.
    private func summarize() {
        defer {
            late = [:]
            reported = 0
            minuteStart = Date()
        }
        guard !late.isEmpty else { return }
        let parts = late.sorted { $0.key < $1.key }.map { screen, seen in
            "\(screen) \(seen.count) late over \(Int(Self.lateMs)) ms, worst \(Int(seen.worst)) ms"
        }
        let draws = drawSummary().map { "; \($0)" } ?? ""
        Log.shared.info("Main thread in the last minute: " + parts.joined(separator: ", ") + draws)
    }
}
