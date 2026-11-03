import AVFoundation
import CoreVideo
import VLCore

/// Writes GPU frames and microphone audio to a QuickTime file. When the encoder cannot
/// keep up it drops frames and counts them rather than holding up the pipeline.
public final class VideoEncoder: VideoFrameSink {
    public struct Config {
        public var url: URL
        public var preset: EncoderPreset
        public var size: EncoderSize
        /// The rate the codec plans for. Timing comes from each frame's own timestamp.
        public var frameRate: Double
        public var audio: Bool
        /// 24-bit PCM instead of AAC.
        public var pcmAudio: Bool
        /// Two for stereo. The writer converts if the microphone gives otherwise.
        public var audioChannels: Int
        /// Real-time mode drops frames when busy; benchmarks turn it off and wait instead.
        public var realTime: Bool
        public var metadata: [String: String]
        /// Clockwise turn for playback, in degrees. The pixels stay as the sensor recorded them.
        public var rotationDegrees: Int
        public var fileTag: FileTag

        public init(
            url: URL, preset: EncoderPreset, size: EncoderSize, frameRate: Double = 30, audio: Bool,
            pcmAudio: Bool = false, audioChannels: Int = 1, realTime: Bool = true, metadata: [String: String] = [:], rotationDegrees: Int = 0,
            fileTag: FileTag = .rec2020
        ) {
            self.url = url
            self.preset = preset
            self.size = size
            self.frameRate = frameRate
            self.audio = audio
            self.pcmAudio = pcmAudio
            self.audioChannels = audioChannels
            self.realTime = realTime
            self.metadata = metadata
            self.fileTag = fileTag
            self.rotationDegrees = rotationDegrees
        }
    }

    public struct Result: Codable, Sendable {
        public var file: String
        public var preset: String
        public var width: Int
        public var height: Int
        public var framesWritten: Int
        public var framesDropped: Int
        public var droppedNoBuffer: Int
        public var droppedNotReady: Int
        public var audioSamplesWritten: Int
        public var seconds: Double
        public var fps: Double
        public var megabytes: Double
        public var megabytesPerSecond: Double
        public var failure: String?
        public var metadata: [String: String]
        /// Frames lost before reaching the encoder. Missing from older sidecars.
        public var droppedAtGPU: Int?
        public var missed: Int?
        public var duplicates: Int?
        public var captureFPS: Double?
    }

    public enum Failure: Error {
        case unsupportedSettings
        case cannotCreatePool
        case cannotStart(String)
    }

    /// Runs on the main queue once if the writer fails mid-recording.
    public var onFailure: ((String) -> Void)?
    /// Runs on the encoder queue with the first frame's time, in seconds.
    public var onFirstFrame: ((Double) -> Void)?

    private let config: Config
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let pool: CVPixelBufferPool
    private let queue = DispatchQueue(label: "vibelog.encoder", qos: .userInitiated)

    private var sessionStarted = false
    private var finished = false
    private var firstTime: CMTime?
    private var lastTime: CMTime?
    private var lastAudioTime: CMTime?
    private var framesWritten = 0
    private var framesDropped = 0
    private var audioSamples = 0
    private var failureReported = false
    private var droppedNoBuffer = 0
    private var droppedNotReady = 0
    private var droppedOutOfOrder = 0
    private var lastWrite = Date()
    /// Real-time input should never refuse frames for this long unless the encoder has stalled.
    private let stallSeconds = 3.0

    public init(config: Config) throws {
        self.config = config
        try? FileManager.default.removeItem(at: config.url)
        writer = try AVAssetWriter(outputURL: config.url, fileType: .mov)
        // Long recordings stay playable up to the last fragment if the app is killed.
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        let settings = config.preset.outputSettings(
            width: config.size.width, height: config.size.height, frameRate: config.frameRate,
            tag: config.fileTag)
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw Failure.unsupportedSettings
        }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = config.realTime
        videoInput.mediaTimeScale = FrameRates.mediaTimeScale(config.frameRate)
        videoInput.transform = CGAffineTransform(rotationAngle: CGFloat(config.rotationDegrees) * .pi / 180)
        guard writer.canAdd(videoInput) else { throw Failure.unsupportedSettings }
        writer.add(videoInput)

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: config.preset.pixelFormat,
            kCVPixelBufferWidthKey as String: config.size.width,
            kCVPixelBufferHeightKey as String: config.size.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: attributes)

        var created: CVPixelBufferPool?
        let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey as String: 4]
        CVPixelBufferPoolCreate(nil, poolAttributes as CFDictionary, attributes as CFDictionary, &created)
        guard let created else { throw Failure.cannotCreatePool }
        pool = created

        if config.audio {
            let audioSettings = Self.audioSettings(pcm: config.pcmAudio, channels: config.audioChannels)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                Log.shared.warn("Writer cannot take audio, recording without it")
                audioInput = nil
            }
        } else {
            audioInput = nil
        }

        guard writer.startWriting() else {
            throw Failure.cannotStart(writer.error?.localizedDescription ?? "unknown")
        }
    }

    /// AAC gets 192 kbps a channel.
    static func audioSettings(pcm: Bool, channels: Int = 1) -> [String: Any] {
        guard pcm else {
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 192_000 * channels,
            ]
        }
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// Fails instead of growing the pool, so a slow encoder shows up as dropped frames.
    public func nextPixelBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let auxiliary = [kCVPixelBufferPoolAllocationThresholdKey as String: 10] as CFDictionary
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, auxiliary, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            // An export waits and asks again, so a missing buffer there loses nothing.
            guard config.realTime else { return nil }
            queue.async { [self] in
                framesDropped += 1
                droppedNoBuffer += 1
                checkForStall()
            }
            return nil
        }
        return buffer
    }

    public func append(_ buffer: CVPixelBuffer, at time: CMTime) {
        queue.async { [self] in
            guard !finished else { return }
            guard writer.status == .writing else {
                framesDropped += 1
                reportFailure()
                return
            }
            if !sessionStarted {
                writer.startSession(atSourceTime: time)
                sessionStarted = true
                firstTime = time
                onFirstFrame?(CMTimeGetSeconds(time))
            }
            // GPU completions can arrive out of order under load, and the writer fails for good
            // on a timestamp that doesn't advance.
            if let lastTime, time <= lastTime {
                framesDropped += 1
                droppedOutOfOrder += 1
                if droppedOutOfOrder == 1 || droppedOutOfOrder % 50 == 0 {
                    let behind = CMTimeGetSeconds(lastTime - time) * 1000
                    Log.shared.warn("Dropped a frame \(behind) ms behind the last one, count \(droppedOutOfOrder)")
                }
                return
            }
            if !config.realTime {
                while !videoInput.isReadyForMoreMediaData, writer.status == .writing {
                    usleep(500)
                }
            }
            if videoInput.isReadyForMoreMediaData, adaptor.append(buffer, withPresentationTime: time) {
                framesWritten += 1
                lastTime = time
                lastWrite = Date()
            } else {
                framesDropped += 1
                droppedNotReady += 1
                reportFailure()
                checkForStall()
            }
        }
    }

    public func appendAudio(_ sample: CMSampleBuffer) {
        queue.async { [self] in
            guard !finished, sessionStarted, let audioInput, let firstTime,
                CMSampleBufferGetPresentationTimeStamp(sample) >= firstTime,
                audioInput.isReadyForMoreMediaData
            else { return }
            if audioInput.append(sample) {
                audioSamples += 1
                lastAudioTime = CMSampleBufferGetPresentationTimeStamp(sample)
            }
        }
    }

    /// Closes the file. The completion runs on the main queue.
    public func finish(completion: @escaping (Result) -> Void) {
        queue.async { [self] in
            finished = true
            guard sessionStarted else {
                writer.cancelWriting()
                let result = makeResult(failure: "No frames were written")
                DispatchQueue.main.async { completion(result) }
                return
            }
            videoInput.markAsFinished()
            audioInput?.markAsFinished()
            writer.finishWriting { [self] in
                let failure = writer.status == .completed
                    ? nil : writer.error.map { describe($0) } ?? "Writer status \(writer.status.rawValue)"
                let result = makeResult(failure: failure)
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    /// Written and dropped frame counts, for progress reports.
    public func counts(completion: @escaping (_ written: Int, _ dropped: Int) -> Void) {
        queue.async { [self] in completion(framesWritten, framesDropped) }
    }

    /// A stalled writer reports no error and would otherwise record nothing until stopped.
    private func checkForStall() {
        guard config.realTime, sessionStarted, !failureReported,
            Date().timeIntervalSince(lastWrite) > stallSeconds
        else { return }
        failureReported = true
        let message = "Encoder stalled after \(framesWritten) frames: writer status \(writer.status.rawValue), "
            + "video ready \(videoInput.isReadyForMoreMediaData), audio ready \(audioInput?.isReadyForMoreMediaData ?? false), "
            + "audio samples \(audioSamples), dropped \(droppedNoBuffer) no buffer, \(droppedNotReady) not ready"
        DispatchQueue.main.async { [self] in onFailure?(message) }
    }

    private func reportFailure() {
        guard !failureReported, writer.status == .failed else { return }
        failureReported = true
        let last = lastTime.map { CMTimeGetSeconds($0) } ?? 0
        let audio = lastAudioTime.map { CMTimeGetSeconds($0) } ?? 0
        let message = (writer.error.map { describe($0) } ?? "Writer failed")
            + " after \(framesWritten) frames, last video \(last), last audio \(audio), "
            + "\(droppedOutOfOrder) out of order, rotation \(config.rotationDegrees), "
            + "thermal \(SystemStatus.thermalName), free \(SystemStatus.freeDisk / 1_000_000_000) GB"
        DispatchQueue.main.async { [self] in onFailure?(message) }
    }

    private func describe(_ error: Error) -> String {
        let details = error as NSError
        let underlying = (details.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? 0
        return "\(details.domain) \(details.code), underlying \(underlying): \(details.localizedDescription)"
    }

    private func makeResult(failure: String?) -> Result {
        let seconds = firstTime.flatMap { first in lastTime.map { CMTimeGetSeconds($0 - first) } } ?? 0
        let values = try? config.url.resourceValues(forKeys: [.fileSizeKey])
        let megabytes = Double(values?.fileSize ?? 0) / 1_000_000
        return Result(
            file: config.url.lastPathComponent, preset: config.preset.label, width: config.size.width,
            height: config.size.height, framesWritten: framesWritten, framesDropped: framesDropped,
            droppedNoBuffer: droppedNoBuffer, droppedNotReady: droppedNotReady,
            audioSamplesWritten: audioSamples, seconds: seconds,
            fps: seconds > 0 ? Double(framesWritten - 1) / seconds : 0, megabytes: megabytes,
            megabytesPerSecond: seconds > 0 ? megabytes / seconds : 0, failure: failure,
            metadata: config.metadata)
    }
}
