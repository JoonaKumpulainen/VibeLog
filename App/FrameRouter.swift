import Foundation
import VLCore
import VLProcessing
import VLRecording

/// Fans frames out from the capture thread to stats, preview and the active recorder.
final class FrameRouter {
    let stats = FrameStats()
    var pipeline: ProcessingPipeline?
    var onRecordingElapsed: (() -> Void)?

    /// The camera's values when the newest frame arrived.
    struct CaptureValues {
        var exposureSeconds = 0.0
        var iso: Float = 0
        var gains: [Float] = []
    }

    var latestCapture: CaptureValues {
        lock.lock()
        defer { lock.unlock() }
        return capture
    }

    private let lock = NSLock()
    private var capture = CaptureValues()
    private var recorder: RawRecorder?
    private var recordSeconds = 0.0
    private var recordStartPTS: Double?
    private var elapsedSignalled = false

    func beginRecording(_ recorder: RawRecorder, seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        self.recorder = recorder
        recordSeconds = seconds
        recordStartPTS = nil
        elapsedSignalled = false
    }

    func endRecording() -> RawRecorder? {
        lock.lock()
        defer { lock.unlock() }
        let finished = recorder
        recorder = nil
        return finished
    }

    func handle(_ frame: RawFrame) {
        stats.recordFrame(pts: frame.pts)
        pipeline?.submit(frame)

        lock.lock()
        capture = CaptureValues(
            exposureSeconds: frame.exposureSeconds, iso: frame.iso, gains: frame.whiteBalanceGains)
        let active = recorder
        var elapsed = false
        if active != nil {
            let start = recordStartPTS ?? frame.pts
            recordStartPTS = start
            if frame.pts - start >= recordSeconds, !elapsedSignalled {
                elapsedSignalled = true
                elapsed = true
            }
        }
        lock.unlock()

        if elapsed {
            onRecordingElapsed?()
        } else if active?.append(frame) == false {
            stats.recordWriterDrop()
        }
    }

    func handleDrop(_ reason: String) {
        stats.recordCaptureDrop()
        activeRecorder()?.recordCaptureDrop()
    }

    func handleFailure() {
        stats.recordCaptureFailure()
        activeRecorder()?.recordCaptureFailure()
    }

    func activeRecorder() -> RawRecorder? {
        lock.lock()
        defer { lock.unlock() }
        return recorder
    }
}
