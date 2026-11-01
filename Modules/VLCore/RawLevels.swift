import CoreVideo
import Foundation

/// Black and white levels for `AVCapturePhoto.pixelBuffer`, read from the photo's {DNG}
/// metadata. The DNG file on an iPhone 14 Pro lists these divided by four (528 and 4095
/// against 2112 and 16383), so the file's tags must not be applied to the buffer.
public struct RawLevels: Codable, Equatable, Sendable {
    public var black: [Double]
    public var white: Double

    public init(black: [Double], white: Double) {
        self.black = black
        self.white = white
    }

    /// Where sensor values really stop. On an iPhone 14 Pro at ISO 100 highlights clip at
    /// exactly 14271, which is the stated white level minus the black level.
    public var clipValue: Double { white - (black.first ?? 0) }

    public init?(photoMetadata: [String: Any]) {
        guard let dng = photoMetadata["{DNG}"] as? [AnyHashable: Any],
            let white = (dng["WhiteLevel"] as? NSNumber)?.doubleValue
        else { return nil }
        if let values = dng["BlackLevel"] as? [NSNumber], !values.isEmpty {
            black = values.map(\.doubleValue)
        } else if let value = dng["BlackLevel"] as? NSNumber {
            black = [value.doubleValue]
        } else {
            return nil
        }
        self.white = white
    }
}

/// A sparse look at one Bayer frame, cheap enough to run on every captured frame.
public struct FrameSample: Codable, Equatable, Sendable {
    public var min: UInt16
    public var max: UInt16
    public var mean: Double
    public var hash: UInt64
}

public enum FrameSampler {
    /// Samples a 16-bit container on a grid. Sensor noise makes equal hashes between
    /// frames impossible unless the pipeline repeated a frame.
    public static func sample(
        base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int, step: Int = 64
    ) -> FrameSample? {
        guard width > 0, height > 0, step > 0, bytesPerRow >= width * 2 else { return nil }
        var low = UInt16.max
        var high = UInt16.min
        var total: UInt64 = 0
        var count: UInt64 = 0
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for y in stride(from: 0, to: height, by: step) {
            let row = base + y * bytesPerRow
            for x in stride(from: 0, to: width, by: step) {
                let value = row.loadUnaligned(fromByteOffset: x * 2, as: UInt16.self)
                low = Swift.min(low, value)
                high = Swift.max(high, value)
                total += UInt64(value)
                count += 1
                hash = (hash ^ UInt64(value)) &* 0x100_0000_01b3
            }
        }
        return FrameSample(min: low, max: high, mean: Double(total) / Double(count), hash: hash)
    }

    public static func sample(_ buffer: CVPixelBuffer) -> FrameSample? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard !CVPixelBufferIsPlanar(buffer), let base = CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }
        return sample(
            base: base, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
    }
}
