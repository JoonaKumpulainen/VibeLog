import CoreVideo
import Foundation

public enum PixelFormats {
    public static func fourCC(_ value: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            return String(decoding: bytes, as: UTF8.self)
        }
        return String(format: "0x%08X", value)
    }

    public static func osType(_ code: String) -> OSType {
        code.utf8.prefix(4).reduce(OSType(0)) { ($0 << 8) | OSType($1) }
    }

    /// Bayer and 16-bit candidates that the probe tries on the video output even when
    /// it does not list them. "btp2" is CoreVideo's versatile packed 12-bit Bayer.
    public static let forcedVideoCandidates: [OSType] = [
        kCVPixelFormatType_14Bayer_RGGB,
        kCVPixelFormatType_14Bayer_BGGR,
        kCVPixelFormatType_14Bayer_GRBG,
        kCVPixelFormatType_14Bayer_GBRG,
        osType("btp2"),
        kCVPixelFormatType_OneComponent16,
    ]
}

/// Bayer color filter order of the top-left 2x2 block.
public enum CFAPattern: String, Codable, Sendable {
    case rggb = "RGGB"
    case bggr = "BGGR"
    case grbg = "GRBG"
    case gbrg = "GBRG"

    public init?(pixelFormat: OSType) {
        switch pixelFormat {
        case kCVPixelFormatType_14Bayer_RGGB: self = .rggb
        case kCVPixelFormatType_14Bayer_BGGR: self = .bggr
        case kCVPixelFormatType_14Bayer_GRBG: self = .grbg
        case kCVPixelFormatType_14Bayer_GBRG: self = .gbrg
        default: return nil
        }
    }

    public init?(dngPattern: [Double]) {
        guard dngPattern.count == 4 else { return nil }
        switch dngPattern.map({ Int($0) }) {
        case [0, 1, 1, 2]: self = .rggb
        case [2, 1, 1, 0]: self = .bggr
        case [1, 0, 2, 1]: self = .grbg
        case [1, 2, 0, 1]: self = .gbrg
        default: return nil
        }
    }

    /// Column and row of the red sample in the 2x2 block.
    public var redOffset: (x: UInt32, y: UInt32) {
        switch self {
        case .rggb: return (0, 0)
        case .bggr: return (1, 1)
        case .grbg: return (1, 0)
        case .gbrg: return (0, 1)
        }
    }

    /// Column and row of the blue sample in the 2x2 block.
    public var blueOffset: (x: UInt32, y: UInt32) {
        let red = redOffset
        return (1 - red.x, 1 - red.y)
    }
}
