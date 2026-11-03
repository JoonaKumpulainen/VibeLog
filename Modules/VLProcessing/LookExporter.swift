import AVFoundation
import CoreGraphics
import Metal
import VLCore

/// Writes a take again with a look baked in, frame by frame, as fast as the phone manages. Each
/// frame is turned back into the log image and encoded through the same look step a baked take
/// uses, so both give the same picture. The original file is only read.
public final class LookExporter {
    public struct Look: Sendable {
        public var curve: LogCurve
        public var gamut: Gamut
        /// Nil bakes the Rec.709 view alone.
        public var lut: CubeLUT?
        public var lutExpectsRec709: Bool
        /// The source was encoded in Rec.709's matrix, as takes tagged Rec.709 are.
        public var sourceRec709: Bool

        public init(curve: LogCurve, gamut: Gamut, lut: CubeLUT?, lutExpectsRec709: Bool, sourceRec709: Bool) {
            self.curve = curve
            self.gamut = gamut
            self.lut = lut
            self.lutExpectsRec709 = lutExpectsRec709
            self.sourceRec709 = sourceRec709
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case noVideo
        case cannotRead(String)
        case gpu
        case encoderFull
        case cancelled

        public var description: String {
            switch self {
            case .noVideo: return "The take has no video track"
            case .cannotRead(let reason): return "Can't read the take: \(reason)"
            case .gpu: return "The GPU couldn't convert a frame"
            case .encoderFull: return "The encoder stopped taking frames"
            case .cancelled: return "Cancelled"
            }
        }
    }

    private let pipeline: ProcessingPipeline
    private let queue: MTLCommandQueue
    private let decodeState: MTLComputePipelineState
    private let previewState: MTLComputePipelineState
    private var cache: CVMetalTextureCache?
    private let look: LookParams
    private let lutTexture: MTLTexture?
    private var sourceLuma: SIMD4<Float>
    private var logImage: MTLTexture?

    public init?(look: Look) {
        guard let pipeline = ProcessingPipeline(), let queue = pipeline.device.makeCommandQueue(),
            let library = try? pipeline.device.makeDefaultLibrary(bundle: Bundle(for: ProcessingPipeline.self)),
            let decode = library.makeFunction(name: "decodeVideo"),
            let preview = library.makeFunction(name: "lookPreview"),
            let decodeState = try? pipeline.device.makeComputePipelineState(function: decode),
            let previewState = try? pipeline.device.makeComputePipelineState(function: preview)
        else { return nil }
        self.pipeline = pipeline
        self.queue = queue
        self.decodeState = decodeState
        self.previewState = previewState
        var settings = ProcessingSettings()
        settings.restore(curve: look.curve, gamut: look.gamut)
        settings.bakeLook = true
        settings.lutExpectsRec709 = look.lutExpectsRec709
        self.look = LookParams(settings: settings, lut: look.lut)
        lutTexture = look.lut.flatMap { pipeline.lutTexture(for: $0) }
        sourceLuma = look.sourceRec709 ? LookParams.rec709Luma : LookParams.rec2020Luma
        CVMetalTextureCacheCreate(nil, nil, pipeline.device, nil, &cache)
    }

    /// Frames come out as 16-bit AYCbCr, which `decodeVideo` reads, with chroma at full size.
    private static let frameSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_4444AYpCbCr16,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
    ]

    /// The take's picture size and length, for sizing the encoder and the progress bar.
    public static func describe(_ url: URL) async throws -> (width: Int, height: Int, seconds: Double) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration)
        return (Int(size.width), Int(size.height), duration.seconds)
    }

    /// The frame at about `seconds`, with the look, `width` pixels wide.
    public func preview(of url: URL, at seconds: Double, width: Int) async throws -> CGImage {
        let (reader, output) = try await makeReader(url, from: seconds)
        defer { reader.cancelReading() }
        guard let sample = output.copyNextSampleBuffer(), let frame = CMSampleBufferGetImageBuffer(sample) else {
            throw Failure.cannotRead(reader.error?.localizedDescription ?? "no frame there")
        }
        let height = max(1, width * CVPixelBufferGetHeight(frame) / max(CVPixelBufferGetWidth(frame), 1))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead]
        guard let small = pipeline.device.makeTexture(descriptor: descriptor),
            let commands = queue.makeCommandBuffer(),
            let decoded = decode(frame, commands: commands),
            let encoder = commands.makeComputeCommandEncoder(),
            let lut = lutTexture ?? pipeline.placeholderTexture
        else { throw Failure.gpu }
        var parameters = look
        encoder.setComputePipelineState(previewState)
        encoder.setTexture(decoded.image, index: 0)
        encoder.setTexture(small, index: 1)
        encoder.setTexture(lut, index: 2)
        encoder.setBytes(&parameters, length: MemoryLayout<LookParams>.stride, index: 0)
        dispatch(encoder, previewState, width: width, height: height)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        withExtendedLifetime(decoded.wrapped) {}
        guard commands.status == .completed else { throw Failure.gpu }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        small.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
            let picture = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw Failure.gpu }
        return picture
    }

    /// Writes every frame into `sink`, at each frame's own time. `progress` gets the share done.
    public func export(
        from url: URL, into sink: VideoFrameSink, seconds: Double, progress: (Double) -> Void,
        cancelled: () -> Bool
    ) async throws {
        let (reader, output) = try await makeReader(url, from: 0)
        defer { reader.cancelReading() }
        var first: CMTime?
        while let sample = output.copyNextSampleBuffer() {
            if cancelled() { throw Failure.cancelled }
            guard let frame = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            first = first ?? time
            // The encoder's pool runs dry while it catches up, so wait for a buffer, but not forever.
            var next = sink.nextPixelBuffer()
            var waits = 0
            while next == nil, waits < 2000 {
                try await Task.sleep(nanoseconds: 5_000_000)
                waits += 1
                next = sink.nextPixelBuffer()
            }
            guard let buffer = next else { throw Failure.encoderFull }
            guard let commands = queue.makeCommandBuffer(), let decoded = decode(frame, commands: commands),
                let planes = pipeline.encodeImage(
                    decoded.image, into: buffer, commands: commands, look: look, lut: lutTexture)
            else { throw Failure.gpu }
            commands.commit()
            commands.waitUntilCompleted()
            withExtendedLifetime((decoded.wrapped, planes)) {}
            guard commands.status == .completed else { throw Failure.gpu }
            sink.append(buffer, at: time)
            if seconds > 0, let first { progress(min((time - first).seconds / seconds, 1)) }
        }
        if reader.status == .failed { throw Failure.cannotRead(reader.error?.localizedDescription ?? "unknown") }
        progress(1)
    }

    private func makeReader(_ url: URL, from seconds: Double) async throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let reader = try AVAssetReader(asset: asset)
        if seconds > 0 {
            reader.timeRange = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 600), duration: .positiveInfinity)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.frameSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw Failure.cannotRead(reader.error?.localizedDescription ?? "unknown")
        }
        return (reader, output)
    }

    /// The frame back as the log image, which is reused frame to frame since each waits for the
    /// last. The wrapped texture must outlive the command buffer.
    private func decode(_ frame: CVPixelBuffer, commands: MTLCommandBuffer) -> (image: MTLTexture, wrapped: CVMetalTexture)? {
        guard let cache else { return nil }
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)
        if logImage?.width != width || logImage?.height != height {
            logImage = pipeline.device.makeTexture(
                descriptor: ProcessingPipeline.outputDescriptor(width: width, height: height))
        }
        var wrapped: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, frame, nil, .rgba16Unorm, width, height, 0, &wrapped) == kCVReturnSuccess,
            let wrapped, let source = CVMetalTextureGetTexture(wrapped), let image = logImage,
            let encoder = commands.makeComputeCommandEncoder()
        else { return nil }
        encoder.setComputePipelineState(decodeState)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(image, index: 1)
        encoder.setBytes(&sourceLuma, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        dispatch(encoder, decodeState, width: width, height: height)
        encoder.endEncoding()
        return (image, wrapped)
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ state: MTLComputePipelineState, width: Int, height: Int) {
        let threadWidth = state.threadExecutionWidth
        let threadHeight = max(state.maxTotalThreadsPerThreadgroup / threadWidth, 1)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1))
    }
}
