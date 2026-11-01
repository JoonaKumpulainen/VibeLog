import Foundation

/// Frame timing measured from capture timestamps, not callback arrival.
public final class FrameStats {
    public struct Snapshot: Codable, Equatable, Sendable {
        public var frames = 0
        public var captureDrops = 0
        public var captureFailures = 0
        public var writerDrops = 0
        public var estimatedMissed = 0
        public var rollingFPS = 0.0
        public var sustainedFPS = 0.0
        public var durationSeconds = 0.0
        public var gapMinMs = 0.0
        public var gapMeanMs = 0.0
        public var gapMedianMs = 0.0
        public var gapP95Ms = 0.0
        public var gapMaxMs = 0.0
        public var gapStdDevMs = 0.0

        public init() {}
    }

    private let lock = NSLock()
    private let rollingWindow: Double
    private var timestamps: [Double] = []
    private var captureDrops = 0
    private var captureFailures = 0
    private var writerDrops = 0

    public init(rollingWindow: Double = 2) {
        self.rollingWindow = rollingWindow
        timestamps.reserveCapacity(4096)
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        timestamps.removeAll(keepingCapacity: true)
        captureDrops = 0
        captureFailures = 0
        writerDrops = 0
    }

    public func recordFrame(pts: Double) {
        lock.lock()
        defer { lock.unlock() }
        timestamps.append(pts)
    }

    public func recordCaptureDrop() {
        lock.lock()
        defer { lock.unlock() }
        captureDrops += 1
    }

    public func recordCaptureFailure() {
        lock.lock()
        defer { lock.unlock() }
        captureFailures += 1
    }

    public func recordWriterDrop() {
        lock.lock()
        defer { lock.unlock() }
        writerDrops += 1
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        let times = timestamps
        var result = Snapshot()
        result.captureDrops = captureDrops
        result.captureFailures = captureFailures
        result.writerDrops = writerDrops
        lock.unlock()

        result.frames = times.count
        guard times.count >= 2, let first = times.first, let last = times.last else {
            return result
        }
        result.durationSeconds = last - first
        if last > first {
            result.sustainedFPS = Double(times.count - 1) / (last - first)
        }
        let recent = times.drop { $0 < last - rollingWindow }
        if recent.count >= 2, let start = recent.first, last > start {
            result.rollingFPS = Double(recent.count - 1) / (last - start)
        }

        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        let sorted = gaps.sorted()
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        let median = sorted[sorted.count / 2]
        let variance = gaps.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(gaps.count)
        result.gapMinMs = sorted[0] * 1000
        result.gapMeanMs = mean * 1000
        result.gapMedianMs = median * 1000
        result.gapP95Ms = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] * 1000
        result.gapMaxMs = sorted[sorted.count - 1] * 1000
        result.gapStdDevMs = variance.squareRoot() * 1000
        if median > 0 {
            result.estimatedMissed = gaps.reduce(0) { total, gap in
                gap > median * 1.5 ? total + Int((gap / median).rounded()) - 1 : total
            }
        }
        return result
    }
}
