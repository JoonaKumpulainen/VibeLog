import Metal
import VLCore

/// Must match EffectsParams in Shaders.metal.
struct EffectsParams {
    var halation: Float = 0
    var bloom: Float = 0
    var diffusion: Float = 0
    var vignette: Float = 0
    var grain: Float = 0
    var frame: Float = 0
    var curve: UInt32 = 0
    var enabled: UInt32 = 0

    init() {}

    init(_ effects: LookEffects, curve: LogCurve, frame: Int) {
        halation = Float(effects.halation)
        bloom = Float(effects.bloom)
        diffusion = Float(effects.diffusion)
        vignette = Float(effects.vignette)
        grain = Float(effects.grain)
        self.frame = Float(frame % 997)
        self.curve = UInt32(curve.rawValue)
        enabled = effects.isNeutral ? 0 : 1
    }
}

/// Makes the glow the effects come from, a blurred eighth-size copy of the picture in linear
/// light, and applies the effects to a whole image for export. The viewfinder applies them per
/// drawn pixel instead, with the same function, so both look alike.
/// A take's glow and effects for the encode kernels, which apply them per pixel before the look.
typealias TakeEffects = (glow: MTLTexture, params: EffectsParams)

extension EffectsParams {
    /// No effects, which the encode kernels take when nothing is baked.
    static let off = EffectsParams(LookEffects(), curve: .appleLog, frame: 0)
}

final class EffectsKit {
    private let device: MTLDevice
    private let downsample: MTLComputePipelineState
    private let blur: MTLComputePipelineState
    private let applyState: MTLComputePipelineState
    /// The glows, taken in turn. A take's kit keeps several, so the glow the viewfinder samples
    /// isn't the one the next queued frames write.
    private var smalls: [MTLTexture] = []
    private var nextSmall = 0
    private let poolSize: Int
    private var scratch: MTLTexture?
    /// Bound when the effects are off, since the viewfinder's shader always takes a glow.
    let placeholder: MTLTexture

    init?(device: MTLDevice, poolSize: Int = 1) {
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle(for: EffectsKit.self)),
            let down = library.makeFunction(name: "effectsDownsample"),
            let blurFunction = library.makeFunction(name: "effectsBlur"),
            let applyFunction = library.makeFunction(name: "effectsApply"),
            let downsample = try? device.makeComputePipelineState(function: down),
            let blur = try? device.makeComputePipelineState(function: blurFunction),
            let applyState = try? device.makeComputePipelineState(function: applyFunction)
        else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let placeholder = device.makeTexture(descriptor: descriptor) else { return nil }
        self.device = device
        self.poolSize = max(poolSize, 1)
        self.downsample = downsample
        self.blur = blur
        self.applyState = applyState
        self.placeholder = placeholder
    }

    /// The glow for `image`, blurred both ways, ready for the same command buffer to sample. It's
    /// an eighth of the full picture each way; `reduction` is 4 for a half-size image, such as the
    /// Efficient path's monitor, so the glow comes out the same size and spread.
    func glow(for image: MTLTexture, params: EffectsParams, commands: MTLCommandBuffer, reduction: Int = 8) -> MTLTexture? {
        let width = max(image.width / reduction, 1)
        let height = max(image.height / reduction, 1)
        if smalls.first?.width != width || smalls.first?.height != height || smalls.count != poolSize {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            smalls = (0..<poolSize).compactMap { _ in device.makeTexture(descriptor: descriptor) }
            scratch = device.makeTexture(descriptor: descriptor)
        }
        guard smalls.count == poolSize, let scratch, let encoder = commands.makeComputeCommandEncoder() else { return nil }
        nextSmall = (nextSmall + 1) % poolSize
        let small = smalls[nextSmall]
        var parameters = params
        encoder.setComputePipelineState(downsample)
        encoder.setTexture(image, index: 0)
        encoder.setTexture(small, index: 1)
        encoder.setBytes(&parameters, length: MemoryLayout<EffectsParams>.stride, index: 0)
        dispatch(encoder, downsample, width: width, height: height)
        for (input, output, direction) in [(small, scratch, SIMD2<Int32>(1, 0)), (scratch, small, SIMD2<Int32>(0, 1))] {
            var step = direction
            encoder.setComputePipelineState(blur)
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            encoder.setBytes(&step, length: MemoryLayout<SIMD2<Int32>>.stride, index: 0)
            dispatch(encoder, blur, width: width, height: height)
        }
        encoder.endEncoding()
        return small
    }

    /// The effects on the whole of `image` into `output`, both full size log images.
    func apply(_ image: MTLTexture, into output: MTLTexture, glow: MTLTexture, params: EffectsParams, commands: MTLCommandBuffer) -> Bool {
        guard let encoder = commands.makeComputeCommandEncoder() else { return false }
        var parameters = params
        encoder.setComputePipelineState(applyState)
        encoder.setTexture(image, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setTexture(glow, index: 2)
        encoder.setBytes(&parameters, length: MemoryLayout<EffectsParams>.stride, index: 0)
        dispatch(encoder, applyState, width: output.width, height: output.height)
        encoder.endEncoding()
        return true
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ state: MTLComputePipelineState, width: Int, height: Int) {
        let threadWidth = state.threadExecutionWidth
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: max(state.maxTotalThreadsPerThreadgroup / threadWidth, 1), depth: 1))
    }
}
