import CoreMedia
import CoreVideo
import Metal
import MetalKit
import VLCore
import simd

public enum DemosaicMethod: UInt32, CaseIterable, Identifiable, Sendable {
    case malvar = 0
    case bilinear = 1

    public var id: UInt32 { rawValue }

    public var label: String {
        switch self {
        case .malvar: return "Malvar-He-Cutler"
        case .bilinear: return "Bilinear"
        }
    }
}

public enum MonitorMode: String, CaseIterable, Identifiable, Sendable {
    case rec709
    case log
    case isp

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .rec709: return "Rec.709 LUT"
        case .log: return "Log"
        case .isp: return "ISP preview"
        }
    }
}

public enum ExposureOverlay: UInt32, CaseIterable, Identifiable, Sendable {
    case none = 0
    case zebras = 1
    case falseColor = 2

    public var id: UInt32 { rawValue }

    public var label: String {
        switch self {
        case .none: return "None"
        case .zebras: return "Zebras"
        case .falseColor: return "False color"
        }
    }
}

public enum PipelineMode: String, CaseIterable, Identifiable, Sendable {
    case maximum
    case efficient

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .maximum: return "Maximum quality"
        case .efficient: return "Efficient"
        }
    }
}

public struct ProcessingSettings: Equatable, Sendable {
    public var enabled = true
    public var pipeline = PipelineMode.maximum
    public var overlay = ExposureOverlay.none
    /// Share of the sensor height kept by the recording crop, dimmed outside on the monitor.
    public var cropFraction = 1.0
    public var pauseMonitorWhileRecording = false
    /// Uses the cheaper debayer and a slower monitor when the phone is hot.
    public var reduceLoadWhenHot = true
    /// Look LUTs expect Rec.709; conversion LUTs expect the log image.
    public var lutExpectsRec709 = false
    public var curve = LogCurve.appleLog
    public var demosaic = DemosaicMethod.malvar
    public var monitor = MonitorMode.rec709
    /// On an iPhone 14 Pro, auto exposure on a plain surface read 0.37 linear at +0.5 stops,
    /// so -0.5 stops places it near 0.18. This is from a single measurement.
    public var exposureStops = -0.5

    public init() {}
}

public struct PipelineStats: Sendable {
    public var processed = 0
    public var dropped = 0
    public var gpuLastMs = 0.0
    public var gpuAverageMs = 0.0
    public var gpuRecentMs = 0.0
    public var gpuMaxMs = 0.0

    public init() {}
}

/// A processed frame read back for export: rgba16Unorm rows in log Rec.2020.
public struct ProcessedStill: Sendable {
    public var pixels: Data
    public var width: Int
    public var height: Int
    public var settings: ProcessingSettings
    public var exposureSeconds: Double
    public var iso: Float
    public var whiteBalanceGains: [Float]
}

private struct FrameCapture {
    var exposureSeconds: Double
    var iso: Float
    var whiteBalanceGains: [Float]
    var pts: Double
}

// Must match ProcessParams in Shaders.metal.
private struct ProcessParams {
    var matrixRow0: SIMD4<Float>
    var matrixRow1: SIMD4<Float>
    var matrixRow2: SIMD4<Float>
    var cfaGain: SIMD4<Float>
    var redOffset: SIMD2<UInt32>
    var curve: UInt32
    var demosaic: UInt32
    var black: Float
    var scale: Float
    var clip: Float
    var exposure: Float
}

private struct MonitorParams {
    var useLUT: UInt32
    var lutSize: Float
    var overlay: UInt32
    var cropFraction: Float
    var lutScale: SIMD4<Float>
    var lutOffset: SIMD4<Float>
    var bandsLow: SIMD4<Float>
    var bandsHigh: SIMD4<Float>
}

private struct CropParams {
    var uvOffset: SIMD2<Float>
    var uvScale: SIMD2<Float>
}

private struct DirectParams {
    var sourceOrigin: SIMD2<Int32>
    var chromaStep: SIMD2<UInt32>
}

/// The encoder buffer for one frame, wrapped as textures the GPU can write.
private struct SinkFrame {
    var sink: VideoFrameSink
    var buffer: CVPixelBuffer
    var wrappedLuma: CVMetalTexture
    var wrappedChroma: CVMetalTexture
    var luma: MTLTexture
    var chroma: MTLTexture
    var time: CMTime
}

private struct CustomLUT {
    var texture: MTLTexture
    var lut: CubeLUT
}

/// Turns Bayer frames into log Rec.2020 on the GPU and shows the result. When work backs up
/// it drops frames and counts them rather than stalling capture.
///
/// Frames are copied into GPU memory first. Holding capture buffers for the length of a GPU
/// pass made photo requests fail, so they go back to the camera within a few milliseconds.
public final class ProcessingPipeline: NSObject {
    public let device: MTLDevice

    private static let lutSize = 33
    /// Three frames absorb the 69 ms GPU spikes seen while encoding.
    private static let maxInFlight = 3
    private static let outputCount = 4

    private let queue: MTLCommandQueue
    private let processState: MTLComputePipelineState
    private let directState: MTLComputePipelineState
    private let monitorKernelState: MTLComputePipelineState
    private let lumaState: MTLComputePipelineState
    private let chromaState: MTLComputePipelineState
    private let monitorState: MTLRenderPipelineState
    private let encodeQueue = DispatchQueue(label: "vibelog.process", qos: .userInitiated)
    private var textureCache: CVMetalTextureCache?
    private weak var view: MTKView?

    private let lock = NSLock()
    private var settings = ProcessingSettings()
    private var calibration: CameraCalibration?
    private var black: Float = 2112
    private var clipValue: Float = 14271
    private var cachedMatrix: (gains: [Float], matrix: simd_double3x3)?
    private var inFlight = 0
    private var inputs: [MTLTexture] = []
    private var nextInput = 0
    private var outputs: [MTLTexture] = []
    private var nextOutput = 0
    private var monitorOutputs: [MTLTexture] = []
    private var nextMonitorOutput = 0
    private var efficientFrames = 0
    private var latest: MTLTexture?
    private var drawScheduled = false
    private var lut: MTLTexture?
    private var lutCurve: LogCurve?
    private var customLUT: CustomLUT?
    private var stats = PipelineStats()
    private var gpuTotalMs = 0.0
    private var stillRequest: ((ProcessedStill?) -> Void)?
    private var sink: VideoFrameSink?
    private var hot = false
    private var drawCounter = 0
    private var loggedFailure = false

    public init?(pixelFormat: MTLPixelFormat = .bgra8Unorm) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            Log.shared.error("Metal is not available")
            return nil
        }
        self.device = device
        self.queue = queue
        do {
            let library = try device.makeDefaultLibrary(bundle: Bundle(for: ProcessingPipeline.self))
            guard let kernel = library.makeFunction(name: "processRaw"),
                let directKernel = library.makeFunction(name: "processDirect"),
                let monitorKernel = library.makeFunction(name: "processMonitor"),
                let lumaKernel = library.makeFunction(name: "encodeLuma"),
                let chromaKernel = library.makeFunction(name: "encodeChroma")
            else {
                Log.shared.error("A pipeline shader is missing")
                return nil
            }
            processState = try device.makeComputePipelineState(function: kernel)
            directState = try device.makeComputePipelineState(function: directKernel)
            monitorKernelState = try device.makeComputePipelineState(function: monitorKernel)
            lumaState = try device.makeComputePipelineState(function: lumaKernel)
            chromaState = try device.makeComputePipelineState(function: chromaKernel)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "monitorVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "monitorFragment")
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            monitorState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            Log.shared.error("Pipeline shader setup failed: \(error.localizedDescription)")
            return nil
        }
        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    /// Reports whether the phone is hot enough to reduce load, if that setting is on.
    public func setHot(_ isHot: Bool) {
        lock.lock()
        let changed = hot != isHot
        hot = isHot
        lock.unlock()
        if changed { Log.shared.warn("Reduced GPU load \(isHot ? "on" : "off")") }
    }

    /// Replaces the Rec.709 monitoring LUT, or restores it when nil.
    public func setCustomLUT(_ lut: CubeLUT?) {
        var custom: CustomLUT?
        if let lut {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type3D
            descriptor.pixelFormat = .rgba16Unorm
            descriptor.width = lut.size
            descriptor.height = lut.size
            descriptor.depth = lut.size
            descriptor.usage = .shaderRead
            if let texture = device.makeTexture(descriptor: descriptor) {
                let samples = lut.textureSamples
                let size = lut.size
                samples.withUnsafeBytes { bytes in
                    texture.replace(
                        region: MTLRegionMake3D(0, 0, 0, size, size, size), mipmapLevel: 0, slice: 0,
                        withBytes: bytes.baseAddress!, bytesPerRow: size * 8, bytesPerImage: size * size * 8)
                }
                custom = CustomLUT(texture: texture, lut: lut)
            }
        }
        lock.lock()
        customLUT = custom
        lock.unlock()
    }

    /// Sends finished frames to an encoder until set back to nil.
    public func setSink(_ newSink: VideoFrameSink?) {
        lock.lock()
        sink = newSink
        lock.unlock()
    }

    public func attach(to view: MTKView) {
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.delegate = self
        self.view = view
    }

    public func update(_ newSettings: ProcessingSettings) {
        lock.lock()
        settings = newSettings
        lock.unlock()
    }

    public func setCalibration(_ metadata: DNGMetadata?, levels: RawLevels?) {
        lock.lock()
        defer { lock.unlock() }
        if let metadata { calibration = CameraCalibration(metadata) }
        if let levels {
            black = Float(levels.black.first ?? 0)
            clipValue = Float(levels.clipValue)
        }
        cachedMatrix = nil
    }

    public func resetStats() {
        lock.lock()
        defer { lock.unlock() }
        stats = PipelineStats()
        gpuTotalMs = 0
    }

    public func currentStats() -> PipelineStats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    /// Reads back the next processed frame.
    public func requestStill(completion: @escaping (ProcessedStill?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        stillRequest = completion
    }

    /// Accepts frames from the capture thread and returns at once.
    public func submit(_ frame: RawFrame) {
        guard let cfa = frame.cfa else { return }
        lock.lock()
        guard settings.enabled else {
            lock.unlock()
            return
        }
        guard inFlight < Self.maxInFlight else {
            stats.dropped += 1
            lock.unlock()
            return
        }
        inFlight += 1
        lock.unlock()
        encodeQueue.async { [self] in
            guard let input = copyToInput(frame) else {
                logOnce("Cannot copy the RAW buffer to the GPU")
                finishFrame(success: false)
                return
            }
            let capture = FrameCapture(
                exposureSeconds: frame.exposureSeconds, iso: frame.iso,
                whiteBalanceGains: frame.whiteBalanceGains, pts: frame.pts)
            // A separate step, so the capture buffer is released before any slow setup.
            encodeQueue.async { [self] in process(input, cfa: cfa, capture: capture) }
        }
    }

    private func copyToInput(_ frame: RawFrame) -> MTLTexture? {
        guard let input = takeInput(width: frame.width, height: frame.height),
            let target = input.buffer?.contents(),
            CVPixelBufferLockBaseAddress(frame.buffer, .readOnly) == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(frame.buffer, .readOnly) }
        guard !CVPixelBufferIsPlanar(frame.buffer), let source = CVPixelBufferGetBaseAddress(frame.buffer) else {
            return nil
        }
        let sourceStride = CVPixelBufferGetBytesPerRow(frame.buffer)
        let rowBytes = min(sourceStride, input.bufferBytesPerRow)
        if sourceStride == input.bufferBytesPerRow {
            memcpy(target, source, rowBytes * frame.height)
        } else {
            for row in 0..<frame.height {
                memcpy(target + row * input.bufferBytesPerRow, source + row * sourceStride, rowBytes)
            }
        }
        return input
    }

    private func takeInput(width: Int, height: Int) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        if inputs.first?.width != width || inputs.first?.height != height {
            let alignment = device.minimumLinearTextureAlignment(for: .r16Uint)
            let stride = (width * 2 + alignment - 1) / alignment * alignment
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r16Uint, width: width, height: height, mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            inputs = (0..<Self.outputCount).compactMap { _ in
                device.makeBuffer(length: stride * height, options: .storageModeShared)?
                    .makeTexture(descriptor: descriptor, offset: 0, bytesPerRow: stride)
            }
        }
        guard inputs.count == Self.outputCount else { return nil }
        nextInput = (nextInput + 1) % Self.outputCount
        return inputs[nextInput]
    }

    private func process(_ input: MTLTexture, cfa: CFAPattern, capture: FrameCapture) {
        guard let commands = queue.makeCommandBuffer() else {
            finishFrame(success: false)
            return
        }
        let sinkFrame = prepareSinkFrame(pts: capture.pts)
        lock.lock()
        let efficient = settings.pipeline == .efficient && stillRequest == nil
        lock.unlock()

        // Stills and resized recordings need the full image.
        let direct = efficient && (sinkFrame == nil || sinkFrame?.luma.width == input.width)
        var image: MTLTexture?
        var still: (() -> Void)?
        var encoded: Bool
        if direct {
            encoded = sinkFrame.map {
                encodeDirect(into: commands, input: input, luma: $0.luma, chroma: $0.chroma, cfa: cfa,
                             gains: capture.whiteBalanceGains)
            } ?? true
            // Every other frame is enough for the monitor while recording.
            efficientFrames += 1
            if sinkFrame == nil || efficientFrames % 2 == 0,
                let monitor = takeMonitorOutput(width: input.width / 2, height: input.height / 2) {
                encoded = encoded && encodeMonitor(
                    into: commands, input: input, output: monitor, cfa: cfa,
                    gains: capture.whiteBalanceGains)
                image = monitor
            }
        } else {
            guard let output = takeOutput(width: input.width, height: input.height) else {
                finishFrame(success: false)
                return
            }
            encoded = encode(into: commands, input: input, output: output, cfa: cfa, gains: capture.whiteBalanceGains)
            if encoded, let sinkFrame {
                encoded = encodeYCbCr(into: commands, image: output, luma: sinkFrame.luma, chroma: sinkFrame.chroma)
            }
            still = encoded ? encodeStillReadback(commands, output: output, capture: capture) : nil
            image = output
        }
        guard encoded else {
            finishFrame(success: false)
            return
        }
        let finalImage = image
        let finalStill = still
        commands.addCompletedHandler { [self] finished in
            let success = finished.status == .completed
            if success, let sinkFrame {
                withExtendedLifetime((sinkFrame.wrappedLuma, sinkFrame.wrappedChroma)) {}
                sinkFrame.sink.append(sinkFrame.buffer, at: sinkFrame.time)
            }
            let milliseconds = (finished.gpuEndTime - finished.gpuStartTime) * 1000
            finishFrame(success: success, image: finalImage, gpuMs: milliseconds)
            finalStill?()
        }
        commands.commit()
    }

    /// Encodes the compute pass. Separate from `process` so tests can run it on plain textures.
    @discardableResult
    func encode(
        into commands: MTLCommandBuffer, input: MTLTexture, output: MTLTexture, cfa: CFAPattern,
        gains: [Float]
    ) -> Bool {
        guard let encoder = commands.makeComputeCommandEncoder() else { return false }
        var parameters = makeParameters(cfa: cfa, gains: gains)
        encoder.setComputePipelineState(processState)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&parameters, length: MemoryLayout<ProcessParams>.stride, index: 0)
        let width = processState.threadExecutionWidth
        let height = max(processState.maxTotalThreadsPerThreadgroup / width, 1)
        encoder.dispatchThreads(
            MTLSize(width: input.width, height: input.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        encoder.endEncoding()
        return true
    }

    /// Gets the encoder's next buffer as textures, or nil when no frame goes to the encoder.
    private func prepareSinkFrame(pts: Double) -> SinkFrame? {
        lock.lock()
        let target = sink
        lock.unlock()
        guard let target, let cache = textureCache, let buffer = target.nextPixelBuffer() else { return nil }

        func wrap(plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
            var texture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, buffer, nil, format, CVPixelBufferGetWidthOfPlane(buffer, plane),
                CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &texture)
            return status == kCVReturnSuccess ? texture : nil
        }
        guard let wrappedLuma = wrap(plane: 0, format: .r16Unorm),
            let wrappedChroma = wrap(plane: 1, format: .rg16Unorm),
            let luma = CVMetalTextureGetTexture(wrappedLuma),
            let chroma = CVMetalTextureGetTexture(wrappedChroma)
        else {
            logOnce("Cannot wrap the encoder's pixel buffer as textures")
            return nil
        }
        return SinkFrame(
            sink: target, buffer: buffer, wrappedLuma: wrappedLuma, wrappedChroma: wrappedChroma,
            luma: luma, chroma: chroma, time: CMTime(seconds: pts, preferredTimescale: 1_000_000_000))
    }

    /// The efficient path: writes the encoder's planes directly from the Bayer data, center
    /// cropping when the planes are shorter than the sensor.
    @discardableResult
    func encodeDirect(
        into commands: MTLCommandBuffer, input: MTLTexture, luma: MTLTexture, chroma: MTLTexture,
        cfa: CFAPattern, gains: [Float]
    ) -> Bool {
        guard let encoder = commands.makeComputeCommandEncoder() else { return false }
        var parameters = makeParameters(cfa: cfa, gains: gains)
        var direct = DirectParams(
            sourceOrigin: SIMD2(Int32((input.width - luma.width) / 2), Int32((input.height - luma.height) / 2)),
            chromaStep: SIMD2(UInt32(luma.width / chroma.width), UInt32(luma.height / chroma.height)))
        encoder.setComputePipelineState(directState)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(luma, index: 1)
        encoder.setTexture(chroma, index: 2)
        encoder.setBytes(&parameters, length: MemoryLayout<ProcessParams>.stride, index: 0)
        encoder.setBytes(&direct, length: MemoryLayout<DirectParams>.stride, index: 1)
        let width = directState.threadExecutionWidth
        let height = max(directState.maxTotalThreadsPerThreadgroup / width, 1)
        encoder.dispatchThreads(
            MTLSize(width: chroma.width, height: chroma.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        encoder.endEncoding()
        return true
    }

    @discardableResult
    func encodeMonitor(
        into commands: MTLCommandBuffer, input: MTLTexture, output: MTLTexture, cfa: CFAPattern,
        gains: [Float]
    ) -> Bool {
        guard let encoder = commands.makeComputeCommandEncoder() else { return false }
        var parameters = makeParameters(cfa: cfa, gains: gains)
        encoder.setComputePipelineState(monitorKernelState)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&parameters, length: MemoryLayout<ProcessParams>.stride, index: 0)
        let width = monitorKernelState.threadExecutionWidth
        let height = max(monitorKernelState.maxTotalThreadsPerThreadgroup / width, 1)
        encoder.dispatchThreads(
            MTLSize(width: output.width, height: output.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        encoder.endEncoding()
        return true
    }

    /// Converts a log image to biplanar 10-bit YCbCr. Separate so tests can use plain textures.
    @discardableResult
    func encodeYCbCr(
        into commands: MTLCommandBuffer, image: MTLTexture, luma: MTLTexture, chroma: MTLTexture
    ) -> Bool {
        guard let encoder = commands.makeComputeCommandEncoder() else { return false }
        var crop = Self.centerCrop(
            imageAspect: Float(image.width) / Float(image.height),
            targetAspect: Float(luma.width) / Float(luma.height))
        for (state, target) in [(lumaState, luma), (chromaState, chroma)] {
            encoder.setComputePipelineState(state)
            encoder.setTexture(image, index: 0)
            encoder.setTexture(target, index: 1)
            encoder.setBytes(&crop, length: MemoryLayout<CropParams>.stride, index: 0)
            let width = state.threadExecutionWidth
            let height = max(state.maxTotalThreadsPerThreadgroup / width, 1)
            encoder.dispatchThreads(
                MTLSize(width: target.width, height: target.height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        }
        encoder.endEncoding()
        return true
    }

    private static func centerCrop(imageAspect: Float, targetAspect: Float) -> CropParams {
        let scale = SIMD2<Float>(min(targetAspect / imageAspect, 1), min(imageAspect / targetAspect, 1))
        return CropParams(uvOffset: (SIMD2(repeating: 1) - scale) * 0.5, uvScale: scale)
    }

    private func makeParameters(cfa: CFAPattern, gains: [Float]) -> ProcessParams {
        lock.lock()
        defer { lock.unlock() }
        let usable = gains.count == 3 && gains[1] > 0 ? gains : [1, 1, 1]
        let red = usable[0] / usable[1]
        let blue = usable[2] / usable[1]
        var cfaGain = SIMD4<Float>(repeating: 1)
        cfaGain[Int(cfa.redOffset.x + 2 * cfa.redOffset.y)] = red
        cfaGain[Int(cfa.blueOffset.x + 2 * cfa.blueOffset.y)] = blue

        let matrix: simd_double3x3
        if let cachedMatrix, cachedMatrix.gains == usable {
            matrix = cachedMatrix.matrix
        } else {
            let neutral = SIMD3<Double>(1 / Double(red), 1, 1 / Double(blue))
            matrix = calibration?.balancedToRec2020(neutral: neutral) ?? matrix_identity_double3x3
            cachedMatrix = (usable, matrix)
        }
        func row(_ index: Int) -> SIMD4<Float> {
            SIMD4(Float(matrix[0][index]), Float(matrix[1][index]), Float(matrix[2][index]), 0)
        }
        return ProcessParams(
            matrixRow0: row(0), matrixRow1: row(1), matrixRow2: row(2), cfaGain: cfaGain,
            redOffset: SIMD2(cfa.redOffset.x, cfa.redOffset.y), curve: settings.curve.rawValue,
            demosaic: (hot && settings.reduceLoadWhenHot ? DemosaicMethod.bilinear : settings.demosaic).rawValue,
            black: black, scale: 1 / (clipValue - black),
            clip: min(red, blue, 1), exposure: Float(pow(2, settings.exposureStops)))
    }

    private func takeOutput(width: Int, height: Int) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        if outputs.first?.width != width || outputs.first?.height != height {
            let descriptor = Self.outputDescriptor(width: width, height: height)
            outputs = (0..<Self.outputCount).compactMap { _ in device.makeTexture(descriptor: descriptor) }
        }
        guard outputs.count == Self.outputCount else {
            logOnceLocked("Cannot allocate output textures")
            return nil
        }
        nextOutput = (nextOutput + 1) % Self.outputCount
        return outputs[nextOutput]
    }

    private func takeMonitorOutput(width: Int, height: Int) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        if monitorOutputs.first?.width != width || monitorOutputs.first?.height != height {
            let descriptor = Self.outputDescriptor(width: width, height: height)
            monitorOutputs = (0..<Self.outputCount).compactMap { _ in device.makeTexture(descriptor: descriptor) }
        }
        guard monitorOutputs.count == Self.outputCount else { return nil }
        nextMonitorOutput = (nextMonitorOutput + 1) % Self.outputCount
        return monitorOutputs[nextMonitorOutput]
    }

    static func outputDescriptor(width: Int, height: Int) -> MTLTextureDescriptor {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return descriptor
    }

    private func encodeStillReadback(
        _ commands: MTLCommandBuffer, output: MTLTexture, capture: FrameCapture
    ) -> (() -> Void)? {
        lock.lock()
        let request = stillRequest
        stillRequest = nil
        let current = settings
        lock.unlock()
        guard let request else { return nil }

        let bytesPerRow = output.width * 8
        guard let buffer = device.makeBuffer(length: bytesPerRow * output.height, options: .storageModeShared),
            let blit = commands.makeBlitCommandEncoder()
        else {
            request(nil)
            return nil
        }
        blit.copy(
            from: output, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: output.width, height: output.height, depth: 1), to: buffer,
            destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: buffer.length)
        blit.endEncoding()
        let width = output.width
        let height = output.height
        return {
            let pixels = Data(bytes: buffer.contents(), count: buffer.length)
            request(ProcessedStill(
                pixels: pixels, width: width, height: height, settings: current,
                exposureSeconds: capture.exposureSeconds, iso: capture.iso,
                whiteBalanceGains: capture.whiteBalanceGains))
        }
    }

    private func finishFrame(success: Bool, image: MTLTexture? = nil, gpuMs: Double = 0) {
        lock.lock()
        inFlight -= 1
        var schedule = false
        if success {
            if let image { latest = image }
            stats.processed += 1
            stats.gpuLastMs = gpuMs
            gpuTotalMs += gpuMs
            stats.gpuAverageMs = gpuTotalMs / Double(stats.processed)
            stats.gpuRecentMs = stats.processed == 1 ? gpuMs : stats.gpuRecentMs * 0.95 + gpuMs * 0.05
            stats.gpuMaxMs = max(stats.gpuMaxMs, gpuMs)
            let paused = settings.pauseMonitorWhileRecording && sink != nil
            drawCounter += 1
            let slowed = hot && settings.reduceLoadWhenHot && drawCounter % 3 != 0
            schedule = image != nil && !drawScheduled && settings.monitor != .isp && !paused && !slowed
            if schedule { drawScheduled = true }
        } else {
            stats.dropped += 1
        }
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.view?.draw()
        }
    }

    private func currentLUT(curve: LogCurve) -> MTLTexture? {
        if lutCurve == curve, let lut { return lut }
        let size = Self.lutSize
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba16Unorm
        descriptor.width = size
        descriptor.height = size
        descriptor.depth = size
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let samples = MonitorTransform.lut(curve: curve, size: size)
        samples.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, size, size, size), mipmapLevel: 0, slice: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: size * 8, bytesPerImage: size * size * 8)
        }
        lut = texture
        lutCurve = curve
        return texture
    }

    private func logOnce(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        logOnceLocked(message)
    }

    private func logOnceLocked(_ message: String) {
        guard !loggedFailure else { return }
        loggedFailure = true
        Log.shared.error(message)
    }
}

extension ProcessingPipeline: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        lock.lock()
        drawScheduled = false
        let image = latest
        let current = settings
        let custom = customLUT
        lock.unlock()
        guard current.monitor != .isp, let image, let rec709 = currentLUT(curve: current.curve),
            let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
            let commands = queue.makeCommandBuffer(),
            let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        let low = custom?.lut.domainMin ?? SIMD3(repeating: 0)
        let high = custom?.lut.domainMax ?? SIMD3(repeating: 1)
        let bands = MonitorBands(curve: current.curve, exposureStops: current.exposureStops)
        var mode: UInt32 = 0
        if current.monitor == .rec709 {
            mode = custom == nil ? 1 : (current.lutExpectsRec709 ? 3 : 2)
        }
        var parameters = MonitorParams(
            useLUT: mode,
            lutSize: Float(custom?.lut.size ?? Self.lutSize), overlay: current.overlay.rawValue,
            cropFraction: Float(current.cropFraction),
            lutScale: SIMD4(1 / (high - low), 0), lutOffset: SIMD4(low, 0),
            bandsLow: SIMD4(bands.blueBelow, bands.greenFrom, bands.greenTo, bands.pinkFrom),
            bandsHigh: SIMD4(bands.pinkTo, bands.yellowFrom, bands.clip, Float(Self.lutSize)))
        encoder.setRenderPipelineState(monitorState)
        encoder.setFragmentTexture(image, index: 0)
        encoder.setFragmentTexture(rec709, index: 1)
        encoder.setFragmentTexture(custom?.texture ?? rec709, index: 2)
        encoder.setFragmentBytes(&parameters, length: MemoryLayout<MonitorParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}
