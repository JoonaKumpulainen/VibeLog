import CoreGraphics
import CoreVideo
import Foundation

/// The export screen's scope. It measures the frames the preview plays, as they'll be written, on
/// the CPU from the compositor's own picture, so it adds no GPU work, and draws the same scopes as
/// the camera's SCOPE tool. About ten a second while playing, and the frame shown after a seek.
public final class PictureScope: @unchecked Sendable {
    struct Counts {
        let columns: Int
        let rows: Int
        var wave: [UInt32]
        var vector: [UInt32]
        var histogram: [UInt32]
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "VibeLog.exportScope", qos: .utility)
    private var kind: ScopeKind?
    private var overlaid = true
    private var deliver: (CGImage?) -> Void = { _ in }
    private var busy = false
    private var last = 0.0
    /// The last frame's counts, so changing the kind redraws a paused picture.
    private var counts: Counts?

    public init() {}

    /// Sets the scope to draw, or none, and redraws the last frame measured.
    public func configure(kind: ScopeKind?, overlaid: Bool, deliver: @escaping (CGImage?) -> Void) {
        lock.lock()
        self.kind = kind
        self.overlaid = overlaid
        self.deliver = deliver
        let counts = self.counts
        lock.unlock()
        draw(counts)
    }

    /// Whether a frame has been measured since the scope was made.
    public var hasFrame: Bool {
        lock.lock()
        defer { lock.unlock() }
        return counts != nil
    }

    /// Called with each frame the preview draws, on the compositor's queue, before it's handed on.
    func measure(_ buffer: CVPixelBuffer) {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        guard kind != nil, !busy, now - last >= 0.09 else {
            lock.unlock()
            return
        }
        busy = true
        last = now
        lock.unlock()
        let counts = Self.count(buffer)
        lock.lock()
        if let counts { self.counts = counts }
        lock.unlock()
        draw(counts, finishing: true)
    }

    private func draw(_ counts: Counts?, finishing: Bool = false) {
        queue.async { [self] in
            lock.lock()
            let (kind, overlaid, deliver) = (self.kind, self.overlaid, self.deliver)
            lock.unlock()
            if let kind, let counts {
                let image = ScopeMeter.render(
                    kind, overlaid: overlaid, columns: counts.columns, rows: counts.rows,
                    wave: counts.wave, vector: counts.vector, histogram: counts.histogram)
                deliver(image)
            } else if kind == nil {
                deliver(nil)
            }
            if finishing {
                lock.lock()
                busy = false
                lock.unlock()
            }
        }
    }

    /// Counts a 256 by 192 grid of an upright BGRA picture, 192 by 256 when it's tall, into the same
    /// bins and levels as the `scopeBins` kernel, with the same Rec.709 luma and colour difference.
    static func count(_ buffer: CVPixelBuffer) -> Counts? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0 else { return nil }
        let wide = width >= height
        let columns = wide ? 256 : 192
        let rows = wide ? 192 : 256
        let levels = ScopeMeter.levels
        let top = Float(levels - 1)
        var wave = [UInt32](repeating: 0, count: 4 * levels * columns)
        var vector = [UInt32](repeating: 0, count: levels * levels)
        var histogram = [UInt32](repeating: 0, count: 4 * levels)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<rows {
            let y = min(Int((Double(row) + 0.5) / Double(rows) * Double(height)), height - 1)
            for column in 0..<columns {
                let x = min(Int((Double(column) + 0.5) / Double(columns) * Double(width)), width - 1)
                let pixel = pixels + y * bytesPerRow + x * 4
                let blue = Float(pixel[0]) / 255
                let green = Float(pixel[1]) / 255
                let red = Float(pixel[2]) / 255
                let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                let values = SIMD4<Float>(luma, red, green, blue)
                for channel in 0..<4 {
                    let level = Int((min(max(values[channel], 0), 1) * top).rounded())
                    wave[(channel * levels + level) * columns + column] += 1
                    histogram[channel * levels + level] += 1
                }
                let cb = (blue - luma) / 1.8556
                let cr = (red - luma) / 1.5748
                let across = Int(min(max(((cb + 0.5) * top).rounded(), 0), top))
                let up = Int(min(max(((0.5 - cr) * top).rounded(), 0), top))
                vector[up * levels + across] += 1
            }
        }
        return Counts(columns: columns, rows: rows, wave: wave, vector: vector, histogram: histogram)
    }
}
