import AVFoundation
import VLCore

/// Microphone capture in its own session, so audio cannot change how the camera session
/// behaves. Its timestamps use the host clock, the same as the camera's.
public final class AudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    public var onSample: ((CMSampleBuffer) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "vibelog.audio", qos: .userInitiated)
    private var configured = false
    private let peakLock = NSLock()
    private var peak: Float = 0

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

    /// The loudest sample since the last call, from 0 to 1.
    public func takePeak() -> Float {
        peakLock.lock()
        defer { peakLock.unlock() }
        let value = peak
        peak = 0
        return value
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
        measure(sampleBuffer)
    }

    /// Reads interleaved 16-bit or 32-bit float PCM. Anything else leaves the meter still.
    private func measure(_ sampleBuffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
            let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
            stream.mFormatID == kAudioFormatLinearPCM,
            let block = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &pointer
        ) == kCMBlockBufferNoErr, let pointer else { return }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: length)
        var loudest: Float = 0
        if stream.mFormatFlags & kAudioFormatFlagIsFloat != 0, stream.mBitsPerChannel == 32 {
            for sample in bytes.bindMemory(to: Float.self) { loudest = max(loudest, abs(sample)) }
        } else if stream.mBitsPerChannel == 16 {
            for sample in bytes.bindMemory(to: Int16.self) {
                loudest = max(loudest, abs(Float(sample)) / 32768)
            }
        } else {
            return
        }
        peakLock.lock()
        peak = max(peak, min(loudest, 1))
        peakLock.unlock()
    }
}
