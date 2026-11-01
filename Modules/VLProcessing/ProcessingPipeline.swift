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

public struct ProcessingSettings: Equatable, Sendable {
    public var enabled = true
    public var curve = LogCurve.appleLog
    public var demosaic = DemosaicMethod.malvar
    public var monitor = MonitorMode.rec709
    /// Half a stop places a typical auto exposure's middle gray near 0.18.
    public var exposureStops = 0.5

    public init() {}
}

public struct PipelineStats: Sendable {
    public var processed = 0
    public var dropped = 0
    public var gpuLastMs = 0.0
    public var gpuAverageMs = 0.0
    public var gpuMaxMs = 0.0

    public init() {}
}

/// A processed frame read back for export: rgba16Unorm rows in log Rec.2020.
public struct ProcessedStill: Sendable {
    public var pixels: Data
    public var width: Int
    public var height: Int
    public var settings: ProcessingSettings
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
}

/// Turns Bayer frames into log Rec.2020 on the GPU and shows the result. When work backs up
/// it drops frames and counts them rather than stalling capture.
public final class ProcessingPipeline: NSObject {
    public let device: MTLDevice

    private static let lutSize = 33
    private static let maxInFlight = 2
    private static let outputCount = 3

    private let queue: MTLCommandQueue
    private let processState: MTLComputePipelineState
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
    private var outputs: [MTLTexture] = []
    private var nextOutput = 0
    private var latest: MTLTexture?
    private var drawScheduled = false
    private var lut: MTLTexture?
    private var lutCurve: LogCurve?
    private var stats = PipelineStats()
    private var gpuTotalMs = 0.0
    private var stillRequest: ((ProcessedStill?) -> Void)?
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
            guard let kernel = library.makeFunction(name: "processRaw") else {
                Log.shared.error("processRaw shader is missing")
                return nil
            }
            processState = try device.makeComputePipelineState(function: kernel)
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
        encodeQueue.async { [self] in process(frame, cfa: cfa) }
    }

    private func process(_ frame: RawFrame, cfa: CFAPattern) {
        guard let cache = textureCache, let output = takeOutput(width: frame.width, height: frame.height),
            let commands = queue.makeCommandBuffer()
        else {
            finishFrame(nil)
            return
        }
        var wrapped: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, frame.buffer, nil, .r16Uint, frame.width, frame.height, 0, &wrapped)
        guard status == kCVReturnSuccess, let wrapped, let input = CVMetalTextureGetTexture(wrapped) else {
            logOnce("Cannot wrap the RAW buffer as a texture (status \(status))")
            finishFrame(nil)
            return
        }
        guard encode(into: commands, input: input, output: output, cfa: cfa, gains: frame.whiteBalanceGains) else {
            finishFrame(nil)
            return
        }
        let still = encodeStillReadback(commands, output: output)
        commands.addCompletedHandler { [self] finished in
            withExtendedLifetime((wrapped, frame)) {}
            let milliseconds = (finished.gpuEndTime - finished.gpuStartTime) * 1000
            finishFrame(finished.status == .completed ? output : nil, gpuMs: milliseconds)
            still?()
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
            demosaic: settings.demosaic.rawValue, black: black, scale: 1 / (clipValue - black),
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

    static func outputDescriptor(width: Int, height: Int) -> MTLTextureDescriptor {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return descriptor
    }

    private func encodeStillReadback(_ commands: MTLCommandBuffer, output: MTLTexture) -> (() -> Void)? {
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
            request(ProcessedStill(pixels: pixels, width: width, height: height, settings: current))
        }
    }

    private func finishFrame(_ output: MTLTexture?, gpuMs: Double = 0) {
        lock.lock()
        inFlight -= 1
        var schedule = false
        if let output {
            latest = output
            stats.processed += 1
            stats.gpuLastMs = gpuMs
            gpuTotalMs += gpuMs
            stats.gpuAverageMs = gpuTotalMs / Double(stats.processed)
            stats.gpuMaxMs = max(stats.gpuMaxMs, gpuMs)
            schedule = !drawScheduled && settings.monitor != .isp
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
        lock.unlock()
        guard current.monitor != .isp, let image, let lut = currentLUT(curve: current.curve),
            let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
            let commands = queue.makeCommandBuffer(),
            let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        var parameters = MonitorParams(
            useLUT: current.monitor == .rec709 ? 1 : 0, lutSize: Float(Self.lutSize))
        encoder.setRenderPipelineState(monitorState)
        encoder.setFragmentTexture(image, index: 0)
        encoder.setFragmentTexture(lut, index: 1)
        encoder.setFragmentBytes(&parameters, length: MemoryLayout<MonitorParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}
