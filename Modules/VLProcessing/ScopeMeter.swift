import CoreGraphics
import Foundation
import Metal

/// The scopes the SCOPE tool cycles through. All measure what the viewfinder shows.
public enum ScopeKind: Int, CaseIterable, Sendable {
    case waveform, parade, yrgbParade, vectorscope, histogram

    public var label: String {
        switch self {
        case .waveform: return "WAVE"
        case .parade: return "RGB"
        case .yrgbParade: return "YRGB"
        case .vectorscope: return "VECTOR"
        case .histogram: return "HIST"
        }
    }

    public var next: ScopeKind { ScopeKind(rawValue: (rawValue + 1) % Self.allCases.count) ?? .waveform }
}

/// Must match ScopeParams in Shaders.metal.
struct ScopeParams {
    var columns: UInt32
    var rows: UInt32
    var turns: UInt32
    var levels: UInt32
}

/// Counts a 192 by 256 grid of the viewfinder's picture into bins on the GPU about ten times a
/// second, then draws the chosen scope as a small image on its own queue, so neither the main
/// thread nor capture waits for it. Waveforms run across the picture as held.
final class ScopeMeter: @unchecked Sendable {
    static let levels = 192
    private static let shortSide = 192
    private static let longSide = 256

    private let state: MTLComputePipelineState
    private let wave: MTLBuffer
    private let vector: MTLBuffer
    private let histogram: MTLBuffer
    private let queue = DispatchQueue(label: "VibeLog.scopes", qos: .utility)
    private let lock = NSLock()
    private var kind = ScopeKind.waveform
    /// RGB and YRGB in one panel, mixing toward white where the channels agree.
    private var overlaid = true
    private var turns = 0
    private var deliver: (CGImage) -> Void = { _ in }
    private var busy = false
    private var frame = 0

    init?(device: MTLDevice) {
        let levels = Self.levels
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle(for: ScopeMeter.self)),
            let function = library.makeFunction(name: "scopeBins"),
            let state = try? device.makeComputePipelineState(function: function),
            let wave = device.makeBuffer(length: 4 * levels * Self.longSide * 4, options: .storageModeShared),
            let vector = device.makeBuffer(length: levels * levels * 4, options: .storageModeShared),
            let histogram = device.makeBuffer(length: 4 * levels * 4, options: .storageModeShared)
        else { return nil }
        self.state = state
        self.wave = wave
        self.vector = vector
        self.histogram = histogram
    }

    func configure(kind: ScopeKind, overlaid: Bool, turns: Int, deliver: @escaping (CGImage) -> Void) {
        lock.lock()
        self.kind = kind
        self.overlaid = overlaid
        self.turns = ((turns % 4) + 4) % 4
        self.deliver = deliver
        lock.unlock()
    }

    /// Every third viewfinder draw, about ten a second, and never while the last is still drawing.
    func wantsFrame() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        frame += 1
        return frame % 3 == 0 && !busy
    }

    /// Adds the count to the viewfinder's own command buffer, with the same look parameters.
    func encode(
        into commands: MTLCommandBuffer, image: MTLTexture, lut: MTLTexture, monitor: UnsafeRawPointer, length: Int
    ) {
        lock.lock()
        let kind = self.kind
        let overlaid = self.overlaid
        let turns = self.turns
        let deliver = self.deliver
        busy = true
        lock.unlock()
        let landscape = turns % 2 == 1
        var params = ScopeParams(
            columns: UInt32(landscape ? Self.longSide : Self.shortSide),
            rows: UInt32(landscape ? Self.shortSide : Self.longSide),
            turns: UInt32(turns), levels: UInt32(Self.levels))
        guard let blit = commands.makeBlitCommandEncoder() else {
            finish()
            return
        }
        for buffer in [wave, vector, histogram] {
            blit.fill(buffer: buffer, range: 0..<buffer.length, value: 0)
        }
        blit.endEncoding()
        guard let encoder = commands.makeComputeCommandEncoder() else {
            finish()
            return
        }
        encoder.setComputePipelineState(state)
        encoder.setTexture(image, index: 0)
        encoder.setTexture(lut, index: 2)
        encoder.setBytes(monitor, length: length, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<ScopeParams>.stride, index: 1)
        encoder.setBuffer(wave, offset: 0, index: 2)
        encoder.setBuffer(vector, offset: 0, index: 3)
        encoder.setBuffer(histogram, offset: 0, index: 4)
        let width = state.threadExecutionWidth
        encoder.dispatchThreads(
            MTLSize(width: Int(params.columns), height: Int(params.rows), depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: max(state.maxTotalThreadsPerThreadgroup / width, 1), depth: 1))
        encoder.endEncoding()
        commands.addCompletedHandler { [self] _ in
            queue.async { [self] in
                let columns = Int(params.columns)
                let image = Self.render(
                    kind, overlaid: overlaid, columns: columns, rows: Int(params.rows),
                    wave: counts(wave, 4 * Self.levels * columns), vector: counts(vector, Self.levels * Self.levels),
                    histogram: counts(histogram, 4 * Self.levels))
                if let image { deliver(image) }
                finish()
            }
        }
    }

    private func finish() {
        lock.lock()
        busy = false
        lock.unlock()
    }

    // MARK: Drawing

    struct Canvas {
        let width: Int
        let height: Int
        var pixels: [UInt8]

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            // A dark, slightly see-through ground, so the scope reads over any picture.
            pixels = [UInt8](repeating: 0, count: width * height * 4)
            for index in 0..<(width * height) {
                pixels[index * 4 + 3] = 170
            }
        }

        /// Adds light, so overlapping channels mix toward white.
        mutating func add(_ x: Int, _ y: Int, _ rgb: (Double, Double, Double), _ amount: Double) {
            guard x >= 0, x < width, y >= 0, y < height, amount > 0 else { return }
            let index = (y * width + x) * 4
            func blend(_ offset: Int, _ value: Double) {
                pixels[index + offset] = UInt8(min(Double(pixels[index + offset]) + value * amount * 255, 255))
            }
            blend(0, rgb.0)
            blend(1, rgb.1)
            blend(2, rgb.2)
            pixels[index + 3] = max(pixels[index + 3], UInt8(min(170 + amount * 85, 255)))
        }

        func image() -> CGImage? {
            guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
            return CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }

    private static let tints: [(Double, Double, Double)] = [(0.85, 0.95, 0.85), (1, 0.25, 0.25), (0.3, 1, 0.35), (0.35, 0.55, 1)]
    private static let line = (0.35, 0.35, 0.35)

    private func counts(_ buffer: MTLBuffer, _ count: Int) -> [UInt32] {
        Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt32.self), count: count))
    }

    /// A count as brightness, on a log scale, so a few samples still show beside many.
    private static func brightness(_ count: UInt32, _ top: Double) -> Double {
        count == 0 ? 0 : min(0.25 + 0.75 * log(1 + Double(count)) / log(1 + top), 1)
    }

    /// Draws the chosen scope from counts laid out as the scope kernel lays them out, from the GPU
    /// or from `PictureScope`.
    static func render(
        _ kind: ScopeKind, overlaid: Bool, columns: Int, rows: Int, wave: [UInt32], vector: [UInt32], histogram: [UInt32]
    ) -> CGImage? {
        let levels = Self.levels
        let rows = Double(rows)
        switch kind {
        case .waveform, .parade, .yrgbParade:
            let channels: [Int] = kind == .waveform ? [0] : kind == .parade ? [1, 2, 3] : [0, 1, 2, 3]
            // Overlaid, every channel shares one panel; otherwise each has its own, side by side.
            let panels = overlaid ? 1 : channels.count
            let gap = 2
            var canvas = Canvas(width: panels * columns + (panels - 1) * gap, height: levels)
            let bins = wave
            for (panel, channel) in channels.enumerated() {
                let left = overlaid ? 0 : panel * (columns + gap)
                for quarter in 0...4 where !overlaid || panel == 0 {
                    let y = (levels - 1) * (4 - quarter) / 4
                    for x in 0..<columns { canvas.add(left + x, y, Self.line, 0.5) }
                }
                for level in 0..<levels {
                    for column in 0..<columns {
                        let count = bins[(channel * levels + level) * columns + column]
                        canvas.add(left + column, levels - 1 - level, Self.tints[channel], Self.brightness(count, rows / 4))
                    }
                }
            }
            return canvas.image()
        case .vectorscope:
            var canvas = Canvas(width: levels, height: levels)
            let center = Double(levels - 1) / 2
            // The edge of Rec.709's colours, and the skin tone line.
            for step in 0..<360 {
                let angle = Double(step) * .pi / 180
                canvas.add(Int(center + cos(angle) * center), Int(center + sin(angle) * center), Self.line, 0.6)
            }
            let skin = 123.0 * .pi / 180
            for step in 0..<Int(center) {
                canvas.add(Int(center + cos(skin) * Double(step)), Int(center - sin(skin) * Double(step)), (0.8, 0.6, 0.4), 0.35)
            }
            // Targets for the six colours at 75%, as on a broadcast vectorscope.
            for target in [(0.75, 0.0, 0.0), (0.0, 0.75, 0.0), (0.0, 0.0, 0.75), (0.75, 0.75, 0.0), (0.0, 0.75, 0.75), (0.75, 0.0, 0.75)] {
                let y = 0.2126 * target.0 + 0.7152 * target.1 + 0.0722 * target.2
                let cb = (target.2 - y) / 1.8556
                let cr = (target.0 - y) / 1.5748
                let x = Int(((cb + 0.5) * Double(levels - 1)).rounded())
                let up = Int(((0.5 - cr) * Double(levels - 1)).rounded())
                for dx in -2...2 {
                    for dy in -2...2 where abs(dx) == 2 || abs(dy) == 2 {
                        canvas.add(x + dx, up + dy, (target.0 / 0.75 * 0.6, target.1 / 0.75 * 0.6, target.2 / 0.75 * 0.6), 0.8)
                    }
                }
            }
            let bins = vector
            let top = Double(bins.max() ?? 1)
            for up in 0..<levels {
                for across in 0..<levels {
                    canvas.add(across, up, Self.tints[0], Self.brightness(bins[up * levels + across], top))
                }
            }
            return canvas.image()
        case .histogram:
            let height = 64
            var canvas = Canvas(width: levels, height: height)
            let bins = histogram
            let top = Double(bins[levels...].max() ?? 1)
            for channel in 1...3 {
                for level in 0..<levels {
                    let share = top > 0 ? Double(bins[channel * levels + level]) / top : 0
                    let bar = Int((share * Double(height - 1)).rounded())
                    for y in 0..<bar { canvas.add(level, height - 1 - y, Self.tints[channel], 0.55) }
                }
            }
            return canvas.image()
        }
    }
}
