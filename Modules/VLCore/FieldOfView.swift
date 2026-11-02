import CoreVideo
import Foundation

/// Tells whether two Bayer frames of the same scene show the same field of view, so the
/// probe can prove a zoomed RAW frame is a real crop rather than trust its dimensions.
public enum FieldOfView {
    public enum Match: String, Sendable {
        case same
        case cropped
        case unclear
    }

    public static let columns = 32
    public static let rows = 24

    /// Average levels on a coarse grid, over the centered `fraction` of a 16-bit container.
    /// Steps stay even, so every sample comes from one color of the Bayer pattern.
    public static func map(
        base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int, fraction: Double = 1
    ) -> [Double]? {
        let regionWidth = Int(Double(width) * fraction)
        let regionHeight = Int(Double(height) * fraction)
        let cellWidth = regionWidth / columns
        let cellHeight = regionHeight / rows
        guard cellWidth >= 2, cellHeight >= 2, bytesPerRow >= width * 2 else { return nil }
        let left = (width - regionWidth) / 2
        let top = (height - regionHeight) / 2
        let step = max(2, (min(cellWidth, cellHeight) / 8) & ~1)

        var values: [Double] = []
        values.reserveCapacity(columns * rows)
        for rowIndex in 0..<rows {
            let startY = (top + rowIndex * cellHeight) & ~1
            for columnIndex in 0..<columns {
                let startX = (left + columnIndex * cellWidth) & ~1
                var total: UInt64 = 0
                var count: UInt64 = 0
                for y in stride(from: startY, to: startY + cellHeight, by: step) {
                    let row = base + y * bytesPerRow
                    for x in stride(from: startX, to: startX + cellWidth, by: step) {
                        total += UInt64(row.loadUnaligned(fromByteOffset: x * 2, as: UInt16.self))
                        count += 1
                    }
                }
                values.append(Double(total) / Double(count))
            }
        }
        return values
    }

    public static func map(_ buffer: CVPixelBuffer, fraction: Double = 1) -> [Double]? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard !CVPixelBufferIsPlanar(buffer), let base = CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }
        return map(
            base: base, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), fraction: fraction)
    }

    /// Pearson correlation, or nil when either map is flat and so proves nothing.
    public static func correlation(_ first: [Double], _ second: [Double]) -> Double? {
        guard first.count == second.count, !first.isEmpty else { return nil }
        let count = Double(first.count)
        let firstMean = first.reduce(0, +) / count
        let secondMean = second.reduce(0, +) / count
        var shared = 0.0
        var firstSpread = 0.0
        var secondSpread = 0.0
        for (a, b) in zip(first, second) {
            shared += (a - firstMean) * (b - secondMean)
            firstSpread += (a - firstMean) * (a - firstMean)
            secondSpread += (b - secondMean) * (b - secondMean)
        }
        guard firstSpread > 0, secondSpread > 0 else { return nil }
        return shared / (firstSpread * secondSpread).squareRoot()
    }

    /// `whole` compares a frame with the reference frame. `center` compares it with the
    /// reference's central area, which is what a true crop would show.
    public static func match(whole: Double?, center: Double?) -> Match {
        let margin = 0.05
        let strong = 0.9
        if let center, center >= strong, center > (whole ?? -1) + margin { return .cropped }
        if let whole, whole >= strong, whole > (center ?? -1) + margin { return .same }
        return .unclear
    }
}
