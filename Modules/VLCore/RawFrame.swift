import CoreVideo
import Foundation

/// One frame from any capture method. The buffer belongs to the capture pipeline:
/// consumers copy what they need and drop their reference quickly.
public final class RawFrame {
    public let buffer: CVPixelBuffer
    public let pts: Double
    public let exposureSeconds: Double
    public let iso: Float
    public let whiteBalanceGains: [Float]

    public init(
        buffer: CVPixelBuffer, pts: Double, exposureSeconds: Double, iso: Float,
        whiteBalanceGains: [Float]
    ) {
        self.buffer = buffer
        self.pts = pts
        self.exposureSeconds = exposureSeconds
        self.iso = iso
        self.whiteBalanceGains = whiteBalanceGains
    }

    public var pixelFormat: OSType { CVPixelBufferGetPixelFormatType(buffer) }
    public var width: Int { CVPixelBufferGetWidth(buffer) }
    public var height: Int { CVPixelBufferGetHeight(buffer) }
    public var cfa: CFAPattern? { CFAPattern(pixelFormat: pixelFormat) }
}

public struct PlaneLayout: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var bytesPerRow: Int
    public var offset: Int
    public var size: Int
}

/// Byte layout of a frame inside frames.raw.
public struct FrameLayout: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixelFormat: String
    public var planes: [PlaneLayout]
    public var bytesPerFrame: Int

    public init(buffer: CVPixelBuffer) {
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
        pixelFormat = PixelFormats.fourCC(CVPixelBufferGetPixelFormatType(buffer))
        var planes: [PlaneLayout] = []
        var offset = 0
        if CVPixelBufferIsPlanar(buffer) {
            for index in 0..<CVPixelBufferGetPlaneCount(buffer) {
                let rows = CVPixelBufferGetHeightOfPlane(buffer, index)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, index)
                planes.append(PlaneLayout(
                    width: CVPixelBufferGetWidthOfPlane(buffer, index), height: rows,
                    bytesPerRow: stride, offset: offset, size: rows * stride))
                offset += rows * stride
            }
        } else {
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            planes.append(PlaneLayout(
                width: width, height: height, bytesPerRow: stride, offset: 0, size: height * stride))
            offset = height * stride
        }
        self.planes = planes
        bytesPerFrame = offset
    }
}
