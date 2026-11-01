import AVFoundation
import VLCore

/// Microphone capture in its own session, so audio cannot change how the camera session
/// behaves. Its timestamps use the host clock, the same as the camera's.
public final class AudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    public var onSample: ((CMSampleBuffer) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "vibelog.audio", qos: .userInitiated)
    private var configured = false

    /// Starts capture on a background queue. Runs `completion` with false without mic access.
    public func start(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { [self] granted in
            guard granted else {
                Log.shared.warn("Microphone permission denied, recording without audio")
                completion(false)
                return
            }
            queue.async { [self] in
                let ready = configure()
                if ready, !session.isRunning { session.startRunning() }
                completion(ready)
            }
        }
    }

    public func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() -> Bool {
        guard !configured else { return true }
        guard let microphone = AVCaptureDevice.default(for: .audio),
            let input = try? AVCaptureDeviceInput(device: microphone), session.canAddInput(input)
        else {
            Log.shared.warn("Microphone is not available")
            return false
        }
        let output = AVCaptureAudioDataOutput()
        guard session.canAddOutput(output) else { return false }
        session.beginConfiguration()
        session.addInput(input)
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        session.commitConfiguration()
        configured = true
        return true
    }

    public func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onSample?(sampleBuffer)
    }
}
