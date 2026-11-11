import AVFoundation
import Metal
import VLCore
import simd

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
        /// The FX tab's effects, applied to each frame before the look.
        public var effects: LookEffects
        /// The LUT gives HDR codes in Rec.2020, written in Rec.2020's matrix.
        public var hdr = false
        /// Where the crop sits within what it leaves out, -1 to 1 along each axis of the stored picture.
        public var cropShift = SIMD2<Float>.zero
        /// Steadies each exported frame from the take's gyro log, or nil to leave them as shot.
        public var steadying: Steadying?

        public init(
            curve: LogCurve, gamut: Gamut, lut: CubeLUT?, lutExpectsRec709: Bool, sourceRec709: Bool,
            effects: LookEffects = LookEffects()
        ) {
            self.curve = curve
            self.gamut = gamut
            self.lut = lut
            self.lutExpectsRec709 = lutExpectsRec709
            self.sourceRec709 = sourceRec709
            self.effects = effects
        }
    }

    /// A take's gyro path with the lens's focal length, in pixels of the picture as stored, and
    /// how far the picture is enlarged to hide its moving edges.
    public struct Steadying: Sendable {
        public var path: SteadyPath
        public var focal: Double
        public var zoom: Double

        public init(path: SteadyPath, focal: Double, zoom: Double) {
            self.path = path
            self.focal = focal
            self.zoom = zoom
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
    private let lightState: MTLComputePipelineState
    private var cache: CVMetalTextureCache?
    // The look can change while the preview plays, through `update`, so these are guarded by
    // `renderLock` whenever `render` reads them.
    private var look: LookParams
    private var lutTexture: MTLTexture?
    private var sourceLuma: SIMD4<Float>
    private var logImage: MTLTexture?
    private var effects: LookEffects
    private var curve: LogCurve
    private var effectsKit: EffectsKit?
    /// One frame at a time: AVFoundation may run more than one compositor over the same exporter,
    /// and the log image and effects textures are shared from frame to frame.
    private let renderLock = NSLock()
    private var effectsImage: MTLTexture?
    private var effectsFrame = 0
    private let cropShift: SIMD2<Float>
    private let steadying: Steadying?
    private let warpState: MTLComputePipelineState?
    private var steadyImage: MTLTexture?

    public init?(look: Look) {
        guard let pipeline = ProcessingPipeline(), let queue = pipeline.device.makeCommandQueue(),
            let library = try? pipeline.device.makeDefaultLibrary(bundle: Bundle(for: ProcessingPipeline.self)),
            let decode = library.makeFunction(name: "decodeVideo"),
            let preview = library.makeFunction(name: "lookPreview"),
            let light = library.makeFunction(name: "lightTiles"),
            let decodeState = try? pipeline.device.makeComputePipelineState(function: decode),
            let previewState = try? pipeline.device.makeComputePipelineState(function: preview),
            let lightState = try? pipeline.device.makeComputePipelineState(function: light)
        else { return nil }
        self.lightState = lightState
        self.pipeline = pipeline
        self.queue = queue
        self.decodeState = decodeState
        self.previewState = previewState
        self.look = Self.params(look)
        lutTexture = look.lut.flatMap { pipeline.lutTexture(for: $0) }
        sourceLuma = look.sourceRec709 ? LookParams.rec709Luma : LookParams.rec2020Luma
        effects = look.effects
        curve = look.curve
        cropShift = look.cropShift
        steadying = look.steadying
        let warp = look.steadying == nil ? nil
            : library.makeFunction(name: "steadyWarp").flatMap { try? pipeline.device.makeComputePipelineState(function: $0) }
        if look.steadying != nil, warp == nil { return nil }
        warpState = warp
        effectsKit = look.effects.isNeutral ? nil : EffectsKit(device: pipeline.device)
        CVMetalTextureCacheCreate(nil, nil, pipeline.device, nil, &cache)
    }

    private static func params(_ look: Look) -> LookParams {
        var settings = ProcessingSettings()
        settings.restore(curve: look.curve, gamut: look.gamut)
        settings.bakeLook = true
        settings.lutExpectsRec709 = look.lutExpectsRec709
        settings.bakeHDR = look.hdr
        return LookParams(settings: settings, lut: look.lut)
    }

    /// A new look for the frames still to come, so the export preview keeps one exporter, with its
    /// GPU state and full-size textures, however often the grade changes. Waits for a frame being
    /// drawn to finish.
    public func update(look: Look) {
        let params = Self.params(look)
        let texture = look.lut.flatMap { pipeline.lutTexture(for: $0) }
        renderLock.lock()
        defer { renderLock.unlock() }
        self.look = params
        lutTexture = texture
        sourceLuma = look.sourceRec709 ? LookParams.rec709Luma : LookParams.rec2020Luma
        effects = look.effects
        curve = look.curve
        if look.effects.isNeutral {
            effectsKit = nil
            effectsImage = nil
        } else if effectsKit == nil {
            effectsKit = EffectsKit(device: pipeline.device)
        }
    }

    /// The frame's log image with the effects on it, or as it is without any. Grain moves from
    /// frame to frame, as it would on film.
    private func withEffects(_ image: MTLTexture, commands: MTLCommandBuffer) -> MTLTexture? {
        guard let effectsKit else { return image }
        effectsFrame += 1
        let params = EffectsParams(effects, curve: curve, frame: effectsFrame)
        if effectsImage?.width != image.width || effectsImage?.height != image.height {
            effectsImage = pipeline.device.makeTexture(
                descriptor: ProcessingPipeline.outputDescriptor(width: image.width, height: image.height))
        }
        guard let effectsImage, let glow = effectsKit.glow(for: image, params: params, commands: commands),
            effectsKit.apply(image, into: effectsImage, glow: glow, params: params, commands: commands)
        else { return nil }
        return effectsImage
    }

    /// The frame's log image steadied for its time in the take, or as it is when the export
    /// doesn't steady. Only the export does this: the preview plays the take as shot.
    private func steadied(_ image: MTLTexture, seconds: Double, commands: MTLCommandBuffer) -> MTLTexture? {
        guard let steadying, let warpState else { return image }
        if steadyImage?.width != image.width || steadyImage?.height != image.height {
            steadyImage = pipeline.device.makeTexture(
                descriptor: ProcessingPipeline.outputDescriptor(width: image.width, height: image.height))
        }
        guard let steadyImage, let encoder = commands.makeComputeCommandEncoder() else { return nil }
        let matrix = steadying.path.matrix(
            at: seconds, width: Double(image.width), height: Double(image.height), focal: steadying.focal,
            zoom: steadying.zoom)
        var warp = simd_float3x3(
            SIMD3<Float>(matrix.columns.0), SIMD3<Float>(matrix.columns.1), SIMD3<Float>(matrix.columns.2))
        encoder.setComputePipelineState(warpState)
        encoder.setTexture(image, index: 0)
        encoder.setTexture(steadyImage, index: 1)
        encoder.setBytes(&warp, length: MemoryLayout<simd_float3x3>.stride, index: 0)
        dispatch(encoder, warpState, width: image.width, height: image.height)
        encoder.endEncoding()
        return steadyImage
    }

    /// Frames come out as 16-bit AYCbCr, which `decodeVideo` reads, with chroma at full size.
    private static let frameSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_4444AYpCbCr16,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
    ]

    /// The take's picture size as stored, length, and how far it turns to play upright, for sizing
    /// and cropping the encoder and for the progress bar.
    public static func describe(_ url: URL) async throws -> (width: Int, height: Int, seconds: Double, quarterTurns: Int) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration)
        let turns = LookPlayback.quarterTurns(try await track.load(.preferredTransform))
        return (Int(size.width), Int(size.height), duration.seconds, turns)
    }

    /// One frame with the look into `output`, a 32BGRA buffer, scaled to its size and turned
    /// `quarterTurns` clockwise, so a take held upright plays upright. For playback, which calls
    /// it from one queue at a time.
    public func render(_ frame: CVPixelBuffer, into output: CVPixelBuffer, quarterTurns: Int = 0) throws {
        renderLock.lock()
        defer { renderLock.unlock() }
        let width = CVPixelBufferGetWidth(output)
        let height = CVPixelBufferGetHeight(output)
        var wrappedOutput: CVMetalTexture?
        guard let cache,
            CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, output, nil, .bgra8Unorm, width, height, 0, &wrappedOutput) == kCVReturnSuccess,
            let wrappedOutput, let target = CVMetalTextureGetTexture(wrappedOutput),
            let commands = queue.makeCommandBuffer(),
            let decoded = decode(frame, commands: commands),
            let source = withEffects(decoded.image, commands: commands),
            let encoder = commands.makeComputeCommandEncoder(),
            let lut = lutTexture ?? pipeline.placeholderTexture
        else { throw Failure.gpu }
        var parameters = look
        var turns = UInt32(((quarterTurns % 4) + 4) % 4)
        encoder.setComputePipelineState(previewState)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(target, index: 1)
        encoder.setTexture(lut, index: 2)
        encoder.setBytes(&parameters, length: MemoryLayout<LookParams>.stride, index: 0)
        encoder.setBytes(&turns, length: MemoryLayout<UInt32>.stride, index: 1)
        dispatch(encoder, previewState, width: width, height: height)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        withExtendedLifetime((decoded.wrapped, wrappedOutput)) {}
        CVMetalTextureCacheFlush(cache, 0)
        guard commands.status == .completed else { throw Failure.gpu }
        // lookPreview writes display codes for Rec.709.
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    /// Writes every frame into `sink`, at each frame's own time. `progress` gets the share done.
    public func export(
        from url: URL, into sink: VideoFrameSink, seconds: Double, progress: (Double) -> Void,
        cancelled: () -> Bool
    ) async throws {
        _ = try await export(
            from: url, seconds: seconds, measuringLight: false, progress: progress, cancelled: cancelled,
            makeSink: { _ in sink })
    }

    /// Writes every frame into the sink `makeSink` gives, at each frame's own time. With
    /// `measuringLight`, an HDR10 export, every frame is first read for MaxCLL and MaxFALL, which
    /// `makeSink` gets before any frame is written, since the encoder needs them from the start. Both
    /// passes read through one reader, rewound between them: a second reader started slowly after the
    /// first, at 72 ms a frame for its first 30, where the rewound one keeps its decoder and buffers.
    /// The light pass takes the first 35% of `progress`.
    public func export(
        from url: URL, seconds: Double, measuringLight: Bool, progress: (Double) -> Void, cancelled: () -> Bool,
        makeSink: ((maxCLL: Int, maxFALL: Int)?) throws -> VideoFrameSink
    ) async throws -> (maxCLL: Int, maxFALL: Int)? {
        let (reader, output, range) = try await makeReader(url, from: 0, randomAccess: measuringLight)
        defer { reader.cancelReading() }
        let lightShare = measuringLight ? 0.35 : 0
        var light: (maxCLL: Int, maxFALL: Int)?
        if measuringLight {
            light = try lightPass(reader: reader, output: output, seconds: seconds, share: lightShare, progress: progress, cancelled: cancelled)
            output.reset(forReadingTimeRanges: [NSValue(timeRange: range)])
        }
        let sink = try makeSink(light)
        var first: CMTime?
        var frames = 0
        // Where each 30 frames' time went: waiting on the encoder, the GPU, and the whole batch.
        var batchStart = Date()
        var waitedSeconds = 0.0
        var gpuSeconds = 0.0
        // Wall time reading a frame, waiting for the GPU's work to finish, and handing the frame
        // to the encoder, which the GPU's own time and the pool wait above leave out.
        var readSeconds = 0.0
        var gpuWallSeconds = 0.0
        var appendSeconds = 0.0
        Log.shared.info("Export memory at start: \(Self.memoryText)")
        while true {
            if cancelled() { throw Failure.cancelled }
            // The encoder's pool runs dry while it catches up, so wait for a buffer, but not forever.
            // The wait suspends, so it stays outside the frame's autorelease pool.
            var next = sink.nextPixelBuffer()
            var waits = 0
            let waitStart = Date()
            while next == nil, waits < 2000 {
                try await Task.sleep(nanoseconds: 5_000_000)
                waits += 1
                next = sink.nextPixelBuffer()
            }
            if waits > 0 { waitedSeconds += Date().timeIntervalSince(waitStart) }
            guard let buffer = next else { throw Failure.encoderFull }
            // A decoded 12 MP frame is about 100 MB, and nothing drains a loop's autoreleased
            // objects or the texture cache by itself, so each frame lets go of its own before the
            // next. Without this a long take runs the app out of memory.
            let finished: Bool = try autoreleasepool {
                let readStart = Date()
                guard let sample = output.copyNextSampleBuffer() else { return true }
                readSeconds += Date().timeIntervalSince(readStart)
                guard let frame = CMSampleBufferGetImageBuffer(sample) else { return false }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                first = first ?? time
                // The gyro log's time zero is the take's first frame.
                let sinceFirst = (time - (first ?? time)).seconds
                guard let commands = queue.makeCommandBuffer(), let decoded = decode(frame, commands: commands),
                    let steady = steadied(decoded.image, seconds: sinceFirst, commands: commands),
                    let source = withEffects(steady, commands: commands),
                    let planes = pipeline.encodeImage(
                        source, into: buffer, commands: commands, look: look, lut: lutTexture, smooth: true,
                        shift: cropShift)
                else { throw Failure.gpu }
                let gpuStart = Date()
                commands.commit()
                commands.waitUntilCompleted()
                gpuWallSeconds += Date().timeIntervalSince(gpuStart)
                withExtendedLifetime((decoded.wrapped, planes)) {}
                if let cache { CVMetalTextureCacheFlush(cache, 0) }
                guard commands.status == .completed else { throw Failure.gpu }
                gpuSeconds += max(commands.gpuEndTime - commands.gpuStartTime, 0)
                let appendStart = Date()
                sink.append(buffer, at: time)
                appendSeconds += Date().timeIntervalSince(appendStart)
                if seconds > 0, let first {
                    progress(lightShare + min((time - first).seconds / seconds, 1) * (1 - lightShare))
                }
                return false
            }
            if finished { break }
            frames += 1
            if frames % 30 == 0 {
                let batch = Date().timeIntervalSince(batchStart)
                Log.shared.info(
                    "Export at frame \(frames): "
                        + String(format: "%.1f fps, gpu %.0f ms a frame, waited %.1f s for the encoder, ",
                            30 / max(batch, 0.001), gpuSeconds / 30 * 1000, waitedSeconds)
                        + String(format: "a frame: read %.0f ms, gpu wall %.0f ms, append %.0f ms, ",
                            readSeconds / 30 * 1000, gpuWallSeconds / 30 * 1000, appendSeconds / 30 * 1000)
                        + "\(Self.memoryText), thermal \(SystemStatus.thermalName)")
                batchStart = Date()
                waitedSeconds = 0
                gpuSeconds = 0
                readSeconds = 0
                gpuWallSeconds = 0
                appendSeconds = 0
            }
        }
        Log.shared.info("Export memory after \(frames) frames: \(Self.memoryText)")
        if reader.status == .failed { throw Failure.cannotRead(reader.error?.localizedDescription ?? "unknown") }
        progress(1)
        return light
    }

    /// HDR10's MaxCLL and MaxFALL in nits, from a first pass over every frame with the look and
    /// effects, before the export writes any: the brightest pixel in the take, and the brightest
    /// frame's average, each counting a pixel's brightest channel. Only for a PQ look. It measures
    /// the whole frame, so a crop can only make the true values lower.
    private func lightPass(
        reader: AVAssetReader, output: AVAssetReaderTrackOutput, seconds: Double, share: Double,
        progress: (Double) -> Void, cancelled: () -> Bool
    ) throws -> (maxCLL: Int, maxFALL: Int) {
        var first: CMTime?
        var brightest: Float = 0
        var brightestFrame: Float = 0
        var tilesBuffer: MTLBuffer?
        let start = Date()
        var frames = 0
        var readSeconds = 0.0
        var gpuWallSeconds = 0.0
        while true {
            if cancelled() { throw Failure.cancelled }
            let finished: Bool = try autoreleasepool {
                let readStart = Date()
                guard let sample = output.copyNextSampleBuffer() else { return true }
                readSeconds += Date().timeIntervalSince(readStart)
                guard let frame = CMSampleBufferGetImageBuffer(sample) else { return false }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                first = first ?? time
                let height = CVPixelBufferGetHeight(frame)
                let width = CVPixelBufferGetWidth(frame)
                let tileSize = 16
                let across = (width + tileSize - 1) / tileSize
                let down = (height + tileSize - 1) / tileSize
                if tilesBuffer == nil || tilesBuffer!.length < across * down * 8 {
                    tilesBuffer = pipeline.device.makeBuffer(length: across * down * 8, options: .storageModeShared)
                }
                guard let tilesBuffer, let commands = queue.makeCommandBuffer(),
                    let decoded = decode(frame, commands: commands),
                    let source = withEffects(decoded.image, commands: commands),
                    let lut = lutTexture ?? pipeline.placeholderTexture,
                    let encoder = commands.makeComputeCommandEncoder()
                else { throw Failure.gpu }
                var parameters = look
                encoder.setComputePipelineState(lightState)
                encoder.setTexture(source, index: 0)
                encoder.setTexture(lut, index: 2)
                encoder.setBytes(&parameters, length: MemoryLayout<LookParams>.stride, index: 0)
                encoder.setBuffer(tilesBuffer, offset: 0, index: 1)
                encoder.dispatchThreadgroups(
                    MTLSize(width: across, height: down, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: tileSize, height: tileSize, depth: 1))
                encoder.endEncoding()
                let gpuStart = Date()
                commands.commit()
                commands.waitUntilCompleted()
                gpuWallSeconds += Date().timeIntervalSince(gpuStart)
                withExtendedLifetime(decoded.wrapped) {}
                if let cache { CVMetalTextureCacheFlush(cache, 0) }
                guard commands.status == .completed else { throw Failure.gpu }
                let tiles = UnsafeBufferPointer(
                    start: tilesBuffer.contents().assumingMemoryBound(to: SIMD2<Float>.self), count: across * down)
                var total: Float = 0
                for tile in tiles {
                    brightest = max(brightest, tile.x)
                    total += tile.y
                }
                brightestFrame = max(brightestFrame, total / Float(max(width * height, 1)))
                // Only samples with a picture count: a rewound reader also hands one without.
                frames += 1
                if seconds > 0, let first { progress(min((time - first).seconds / seconds, 1) * share) }
                return false
            }
            if finished { break }
        }
        if reader.status == .failed { throw Failure.cannotRead(reader.error?.localizedDescription ?? "unknown") }
        // Grain then starts the export from the same frame it would without the pass.
        effectsFrame = 0
        // MaxFALL can't exceed MaxCLL; rounding up keeps the brightest pixel inside the stated level.
        let maxCLL = Int(brightest.rounded(.up))
        let maxFALL = min(Int(brightestFrame.rounded(.up)), maxCLL)
        Log.shared.info(
            "Export light levels over \(frames) frames in "
                + String(format: "%.1f s, reading %.1f s, GPU %.1f s", Date().timeIntervalSince(start), readSeconds, gpuWallSeconds)
                + ": MaxCLL \(maxCLL) nits, MaxFALL \(maxFALL) nits")
        return (maxCLL, maxFALL)
    }

    /// The app's footprint and what it may still allocate, the two numbers that say how near the
    /// OS is to ending it.
    private static var memoryText: String {
        "footprint \(SystemStatus.footprint / 1_000_000) MB, available \(SystemStatus.availableMemory / 1_000_000) MB"
    }

    /// A reader of the take's frames. With `randomAccess`, its output can be read through again
    /// after reaching the end, keeping its decoder and frame buffers, over the track's time range.
    private func makeReader(
        _ url: URL, from seconds: Double, randomAccess: Bool = false
    ) async throws -> (AVAssetReader, AVAssetReaderTrackOutput, CMTimeRange) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let range = try await track.load(.timeRange)
        let reader = try AVAssetReader(asset: asset)
        if seconds > 0 {
            reader.timeRange = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 600), duration: .positiveInfinity)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.frameSettings)
        output.alwaysCopiesSampleData = false
        output.supportsRandomAccess = randomAccess
        reader.add(output)
        guard reader.startReading() else {
            throw Failure.cannotRead(reader.error?.localizedDescription ?? "unknown")
        }
        return (reader, output, range)
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
