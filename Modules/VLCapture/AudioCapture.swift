import AVFoundation
import VLCore

/// Microphone capture in its own session, so audio cannot change how the camera session
/// behaves. Its timestamps use the host clock, the same as the camera's.
public final class AudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    public var onSample: ((CMSampleBuffer) -> Void)?
    /// The loudest left and right samples of each stretch of about 80 ms, on the audio queue.
    /// Mono gives the same value for both.
    public var onLevels: ((Float, Float) -> Void)?
    /// Asks the built-in microphones for stereo, which iOS 18 offers. It applies from the next
    /// start, and the log says what the microphone gave.
    public var stereo = true {
        didSet { queue.async { [self] in applyStereo() } }
    }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "vibelog.audio", qos: .userInitiated)
    private var configured = false
    private let peakLock = NSLock()
    private var peak: Float = 0
    private var levelPeaks: (left: Float, right: Float) = (0, 0)
    private var input: AVCaptureDeviceInput?
    private var levelFrames = 0
    private var loggedFormat = false

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
        self.input = input
        configured = true
        applyStereo()
        return true
    }

    private func applyStereo() {
        guard let input else { return }
        guard #available(iOS 18.0, *), input.isMultichannelAudioModeSupported(.stereo) else {
            if stereo { Log.shared.warn("Stereo audio isn't supported here, recording mono") }
            return
        }
        let mode: AVCaptureMultichannelAudioMode = stereo ? .stereo : .none
        guard input.multichannelAudioMode != mode else { return }
        session.beginConfiguration()
        input.multichannelAudioMode = mode
        session.commitConfiguration()
        loggedFormat = false
        Log.shared.info("Microphone set to \(stereo ? "stereo" : "mono")")
    }

    public func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onSample?(sampleBuffer)
        measure(sampleBuffer)
    }

    /// Reads 16-bit or 32-bit PCM. Anything else leaves the meter still, and the log says why.
    private func measure(_ sampleBuffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
            let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
            stream.mFormatID == kAudioFormatLinearPCM,
            let block = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { return }
        if !loggedFormat {
            loggedFormat = true
            Log.shared.info("Audio format: \(stream.mSampleRate) Hz, \(stream.mBitsPerChannel) bit, \(stream.mChannelsPerFrame) channels, flags \(stream.mFormatFlags)")
        }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &pointer
        ) == kCMBlockBufferNoErr, let pointer else { return }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: length)
        let channels = max(Int(stream.mChannelsPerFrame), 1)
        let interleaved = stream.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        guard let loudest = AudioLevels.channelPeaks(
            bytes, bits: Int(stream.mBitsPerChannel), float: stream.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            channels: channels, interleaved: interleaved)
        else { return }
        peakLock.lock()
        peak = max(peak, min(max(loudest.left, loudest.right), 1))
        peakLock.unlock()
        levelPeaks = (max(levelPeaks.left, min(loudest.left, 1)), max(levelPeaks.right, min(loudest.right, 1)))
        levelFrames += CMSampleBufferGetNumSamples(sampleBuffer)
        guard Double(levelFrames) >= stream.mSampleRate * 0.08 else { return }
        onLevels?(levelPeaks.left, levelPeaks.right)
        levelPeaks = (0, 0)
        levelFrames = 0
    }
}
