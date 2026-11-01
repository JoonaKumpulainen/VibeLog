import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VLCore
import simd

/// Writes a processed frame to Documents/stills for checking the pipeline on a computer.
public enum StillExporter {
    public struct Spot: Codable, Sendable {
        public var log: [Double]
        public var linear: [Double]
    }

    private struct Summary: Codable {
        var curve: String
        var demosaic: String
        var exposureStops: Double
        var width: Int
        var height: Int
        var centerSpot: Spot
    }

    /// Returns the folder and the average of the center of the frame.
    public static func export(_ still: ProcessedStill) throws -> (folder: URL, spot: Spot) {
        let folder = Storage.stills.appendingPathComponent("still_\(Storage.timestamp())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let curve = still.settings.curve
        let spot = centerSpot(still)
        try writePNG(
            data: still.pixels, width: still.width, height: still.height, bytesPerRow: still.width * 8,
            bitsPerComponent: 16, bitsPerPixel: 64,
            info: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
            to: folder.appendingPathComponent("log_rec2020.png"))

        let monitor = monitorPixels(still)
        try writePNG(
            data: monitor.data, width: monitor.width, height: monitor.height, bytesPerRow: monitor.width * 4,
            bitsPerComponent: 8, bitsPerPixel: 32,
            info: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            to: folder.appendingPathComponent("rec709_half.png"))

        let summary = Summary(
            curve: curve.label, demosaic: still.settings.demosaic.label,
            exposureStops: still.settings.exposureStops, width: still.width, height: still.height,
            centerSpot: spot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(summary).write(to: folder.appendingPathComponent("still.json"))
        return (folder, spot)
    }

    private static func pixel(_ bytes: UnsafeRawBufferPointer, x: Int, y: Int, width: Int) -> SIMD3<Double> {
        let offset = (y * width + x) * 8
        func channel(_ index: Int) -> Double {
            Double(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + index * 2, as: UInt16.self))) / 65535
        }
        return SIMD3(channel(0), channel(1), channel(2))
    }

    private static func centerSpot(_ still: ProcessedStill) -> Spot {
        let radius = 32
        var total = SIMD3<Double>(repeating: 0)
        var count = 0.0
        still.pixels.withUnsafeBytes { bytes in
            for y in (still.height / 2 - radius)..<(still.height / 2 + radius) {
                for x in (still.width / 2 - radius)..<(still.width / 2 + radius) {
                    total += pixel(bytes, x: x, y: y, width: still.width)
                    count += 1
                }
            }
        }
        let mean = total / max(count, 1)
        let curve = still.settings.curve
        return Spot(
            log: [mean.x, mean.y, mean.z],
            linear: [curve.decode(mean.x), curve.decode(mean.y), curve.decode(mean.z)])
    }

    private static func monitorPixels(_ still: ProcessedStill) -> (data: Data, width: Int, height: Int) {
        let width = still.width / 2
        let height = still.height / 2
        var output = Data(count: width * height * 4)
        let curve = still.settings.curve
        still.pixels.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            output.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                for y in 0..<height {
                    for x in 0..<width {
                        let color = MonitorTransform.display(
                            log: pixel(bytes, x: x * 2, y: y * 2, width: still.width), curve: curve)
                        let offset = (y * width + x) * 4
                        target[offset] = UInt8(color.x * 255)
                        target[offset + 1] = UInt8(color.y * 255)
                        target[offset + 2] = UInt8(color.z * 255)
                        target[offset + 3] = 255
                    }
                }
            }
        }
        return (output, width, height)
    }

    private static func writePNG(
        data: Data, width: Int, height: Int, bytesPerRow: Int, bitsPerComponent: Int, bitsPerPixel: Int,
        info: CGBitmapInfo, to url: URL
    ) throws {
        guard let provider = CGDataProvider(data: data as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: bitsPerComponent, bitsPerPixel: bitsPerPixel,
                bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
