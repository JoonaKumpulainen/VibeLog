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
        public var audio: Bool
        /// Real-time mode drops frames when busy; benchmarks turn it off and wait instead.
        public var realTime: Bool
        public var metadata: [String: String]

        public init(
            url: URL, preset: EncoderPreset, size: EncoderSize, audio: Bool, realTime: Bool = true,
            metadata: [String: String] = [:]
        ) {
            self.url = url
            self.preset = preset
            self.size = size
            self.audio = audio
            self.realTime = realTime
            self.metadata = metadata
        }
    }

    public struct Result: Codable, Sendable {
        public var file: String
        public var preset: String
        public var width: Int
        public var height: Int
        public var framesWritten: Int
        public var framesDropped: Int
        public var audioSamplesWritten: Int
        public var seconds: Double
        public var fps: Double
        public var megabytes: Double
        public var megabytesPerSecond: Double
        public var failure: String?
        public var metadata: [String: String]
    }

    public enum Failure: Error {
        case unsupportedSettings
        case cannotCreatePool
        case cannotStart(String)
    }

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
    private var framesWritten = 0
    private var framesDropped = 0
    private var audioSamples = 0

    public init(config: Config) throws {
        self.config = config
        try? FileManager.default.removeItem(at: config.url)
        writer = try AVAssetWriter(outputURL: config.url, fileType: .mov)
        // Long recordings stay playable up to the last fragment if the app is killed.
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        let settings = config.preset.outputSettings(width: config.size.width, height: config.size.height)
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw Failure.unsupportedSettings
        }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = config.realTime
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
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 192_000,
            ]
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

    /// Fails instead of growing the pool, so a slow encoder shows up as dropped frames.
    public func nextPixelBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let auxiliary = [kCVPixelBufferPoolAllocationThresholdKey as String: 10] as CFDictionary
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, auxiliary, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            queue.async { [self] in framesDropped += 1 }
            return nil
        }
        return buffer
    }

    public func append(_ buffer: CVPixelBuffer, at time: CMTime) {
        queue.async { [self] in
            guard !finished, writer.status == .writing else { return }
            if !sessionStarted {
                writer.startSession(atSourceTime: time)
                sessionStarted = true
                firstTime = time
            }
            if !config.realTime {
                while !videoInput.isReadyForMoreMediaData, writer.status == .writing {
                    usleep(500)
                }
            }
            if videoInput.isReadyForMoreMediaData, adaptor.append(buffer, withPresentationTime: time) {
                framesWritten += 1
                lastTime = time
            } else {
                framesDropped += 1
            }
        }
    }

    public func appendAudio(_ sample: CMSampleBuffer) {
        queue.async { [self] in
            guard !finished, sessionStarted, let audioInput, let firstTime,
                CMSampleBufferGetPresentationTimeStamp(sample) >= firstTime,
                audioInput.isReadyForMoreMediaData
            else { return }
            if audioInput.append(sample) { audioSamples += 1 }
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
            audioSamplesWritten: audioSamples, seconds: seconds,
            fps: seconds > 0 ? Double(framesWritten - 1) / seconds : 0, megabytes: megabytes,
            megabytesPerSecond: seconds > 0 ? megabytes / seconds : 0, failure: failure,
            metadata: config.metadata)
    }
}
