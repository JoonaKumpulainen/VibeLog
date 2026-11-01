import CoreVideo
import Metal
import MetalKit
import VLCore

private struct PreviewUniforms {
    var redOffset: SIMD2<UInt32>
    var blueOffset: SIMD2<UInt32>
    var black: Float
    var white: Float
    var gains: SIMD3<Float>
}

/// Draws the newest Bayer frame into an MTKView, skipping frames while one is pending.
/// The Phase 2 compute pipeline will live beside this in VLProcessing.
public final class RawPreviewRenderer: NSObject {
    public let device: MTLDevice

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private weak var view: MTKView?

    private let lock = NSLock()
    private var pending: RawFrame?
    private var drawScheduled = false
    private var black: Float = 0
    private var white: Float = 16383
    private var loggedFailure = false

    public init?(pixelFormat: MTLPixelFormat = .bgra8Unorm) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            Log.shared.error("Metal is not available")
            return nil
        }
        self.device = device
        self.queue = queue
        do {
            let library = try device.makeDefaultLibrary(bundle: Bundle(for: RawPreviewRenderer.self))
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "previewVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "previewBayer")
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            Log.shared.error("Preview shader setup failed: \(error.localizedDescription)")
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

    public func setLevels(black: Float, white: Float) {
        lock.lock()
        self.black = black
        self.white = white
        lock.unlock()
    }

    /// Accepts Bayer frames from any thread; other formats are ignored.
    public func submit(_ frame: RawFrame) {
        guard frame.cfa != nil else { return }
        lock.lock()
        pending = frame
        let schedule = !drawScheduled
        drawScheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.view?.draw()
        }
    }

    private func takePending() -> (RawFrame?, Float, Float) {
        lock.lock()
        defer { lock.unlock() }
        let frame = pending
        pending = nil
        drawScheduled = false
        return (frame, black, white)
    }

    private func logOnce(_ message: String) {
        guard !loggedFailure else { return }
        loggedFailure = true
        Log.shared.error(message)
    }
}

extension RawPreviewRenderer: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        let (taken, black, white) = takePending()
        guard let frame = taken, let cfa = frame.cfa, let cache = textureCache,
            let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
            let commands = queue.makeCommandBuffer()
        else { return }

        var wrapped: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, frame.buffer, nil, .r16Uint, frame.width, frame.height, 0, &wrapped)
        guard status == kCVReturnSuccess, let wrapped, let texture = CVMetalTextureGetTexture(wrapped) else {
            logOnce("RAW preview: cannot wrap buffer as a texture (status \(status))")
            return
        }

        let red = cfa.redOffset
        let blue = cfa.blueOffset
        let gains = frame.whiteBalanceGains
        var uniforms = PreviewUniforms(
            redOffset: SIMD2(red.x, red.y), blueOffset: SIMD2(blue.x, blue.y), black: black,
            white: white,
            gains: gains.count == 3 ? SIMD3(gains[0], gains[1], gains[2]) : SIMD3(repeating: 1))

        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PreviewUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.addCompletedHandler { _ in
            withExtendedLifetime((wrapped, frame)) {}
        }
        commands.commit()
    }
}
