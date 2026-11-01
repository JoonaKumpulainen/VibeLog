import CoreMotion
import VLCore

/// Saves a take's motion to a Gyroflow file on its own queue, so it never touches the main thread
/// or the capture path. The file is written once a second, so a killed app loses only the last one.
public final class MotionLogger {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private let rate = 200.0

    // Only used on `queue`.
    private var url: URL?
    private var handle: FileHandle?
    private var firstFrame: Double?
    private var pending: [MotionSample] = []
    private var firstSample: Double?
    private var lastSample = 0.0
    private var written = 0

    public init() {}

    public func start(url: URL, videoName: String, version: String) {
        guard manager.isDeviceMotionAvailable else {
            Log.shared.warn("Device motion is not available, so this take has no gyro log")
            return
        }
        let header = GyroLog.header(videoName: videoName, startedAt: Date(), version: version)
        queue.addOperation { [self] in
            do {
                try Data(header.utf8).write(to: url)
                handle = try FileHandle(forWritingTo: url)
                try handle?.seekToEnd()
                self.url = url
            } catch {
                Log.shared.error("Cannot open gyro log: \(error)")
            }
            firstFrame = nil
            pending = []
            firstSample = nil
            written = 0
        }
        manager.deviceMotionUpdateInterval = 1 / rate
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            if let motion { self?.add(motion) }
        }
    }

    /// Readings start before the first frame, and any from before it are left out.
    public func setFirstFrame(seconds: Double) {
        queue.addOperation { [self] in firstFrame = seconds }
    }

    public func stop() {
        manager.stopDeviceMotionUpdates()
        queue.addOperation { [self] in
            write()
            try? handle?.close()
            handle = nil
            let span = lastSample - (firstSample ?? lastSample)
            if written > 0, span > 0 {
                Log.shared.info(String(format: "Gyro log: %d samples at %.0f Hz", written, Double(written - 1) / span))
            } else if let url {
                // The take wrote no frames, so there's nothing to line this up with.
                try? FileManager.default.removeItem(at: url)
            }
            url = nil
        }
    }

    private func add(_ motion: CMDeviceMotion) {
        guard handle != nil else { return }
        let rotation = motion.rotationRate
        let gravity = motion.gravity
        let moving = motion.userAcceleration
        // CoreMotion's gravity points down, and a still camera is pushed up.
        pending.append(MotionSample(
            seconds: motion.timestamp, rotation: SIMD3(rotation.x, rotation.y, rotation.z),
            acceleration: -SIMD3(gravity.x + moving.x, gravity.y + moving.y, gravity.z + moving.z)))
        if pending.count >= Int(rate) { write() }
    }

    private func write() {
        guard let firstFrame, let handle else { return }
        let samples = pending.filter { $0.seconds >= firstFrame }
        pending = []
        guard let first = samples.first, let last = samples.last else { return }
        firstSample = firstSample ?? first.seconds
        lastSample = last.seconds
        written += samples.count
        let text = samples.map { GyroLog.line($0, firstFrame: firstFrame) }.joined()
        do {
            try handle.write(contentsOf: Data(text.utf8))
        } catch {
            Log.shared.error("Gyro log stopped: \(error)")
            try? handle.close()
            self.handle = nil
        }
    }
}
