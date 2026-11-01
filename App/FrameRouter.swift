import Foundation
import VLCore
import VLProcessing
import VLRecording

/// Fans frames out from the capture thread to stats, preview and the active recorder.
final class FrameRouter {
    let stats = FrameStats()
    var preview: RawPreviewRenderer?
    var onRecordingElapsed: (() -> Void)?

    private let lock = NSLock()
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
        preview?.submit(frame)

        lock.lock()
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
