import AVFoundation
import VideoToolbox

/// What a file's color tags say. None changes the pixels, because the real curve and gamut are in
/// the sidecar. Editors read these tags to decide how to show the clip.
public enum FileTag: String, CaseIterable, Identifiable, Sendable {
    case rec2020, rec709, hlg, pq

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .rec2020: return "Rec.2020"
        case .rec709: return "Rec.709"
        case .hlg: return "Rec.2020 HLG"
        case .pq: return "Rec.2020 PQ"
        }
    }

    var colorProperties: [String: String] {
        switch self {
        case .rec2020:
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        case .rec709:
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
        case .hlg:
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        case .pq:
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        }
    }
}

/// A codec and pixel format combination to try. Support varies by device, so the benchmark
/// tests these rather than assuming any of them works.
public struct EncoderPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let codec: AVVideoCodecType
    public let pixelFormat: OSType
    public let profile: String?
    public let bitrate: Int?

    /// The color depth the encoder keeps. Fed 16 bits, ProRes 4444 keeps 12.
    public var bitDepth: Int { pixelFormat == kCVPixelFormatType_4444AYpCbCr16 ? 12 : 10 }

    /// ProRes 4444 fed 16-bit AYCbCr, with opaque alpha, so it keeps its 12 bits of color, proven
    /// on an iPhone 14 Pro. Other presets stay as they are.
    public var twelveBit: EncoderPreset {
        guard codec == .proRes4444 else { return self }
        return EncoderPreset(
            id: id, label: label, codec: codec, pixelFormat: kCVPixelFormatType_4444AYpCbCr16,
            profile: profile, bitrate: bitrate)
    }

    /// The same preset at another average rate, for an export that trades size for quality.
    public func withBitrate(_ value: Int) -> EncoderPreset {
        EncoderPreset(id: id, label: label, codec: codec, pixelFormat: pixelFormat, profile: profile, bitrate: value)
    }

    /// About half the size of ProRes 422 HQ. Offered for exports only, not for recording.
    public static let proRes422LT = EncoderPreset(
        id: "prores422lt", label: "ProRes 422 LT", codec: .proRes422LT,
        pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, profile: nil, bitrate: nil)

    /// Only for the encoder test: whether HEVC writes more than 10 bits when given 16. Apple lists
    /// no 12-bit HEVC profile, so the file may come out 10-bit without any error.
    public static let hevc444From16Bit = EncoderPreset(
        id: "hevc444-16", label: "HEVC 4:4:4 from 16-bit", codec: .hevc,
        pixelFormat: kCVPixelFormatType_4444AYpCbCr16, profile: nil, bitrate: 300_000_000)

    public static let all: [EncoderPreset] = [
        EncoderPreset(
            id: "hevc420", label: "HEVC 10-bit 4:2:0", codec: .hevc,
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            profile: kVTProfileLevel_HEVC_Main10_AutoLevel as String, bitrate: 200_000_000),
        EncoderPreset(
            id: "hevc422", label: "HEVC 10-bit 4:2:2", codec: .hevc,
            pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
            profile: "HEVC_Main42210_AutoLevel", bitrate: 300_000_000),
        EncoderPreset(
            id: "hevc444", label: "HEVC 10-bit 4:4:4", codec: .hevc,
            pixelFormat: kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
            profile: nil, bitrate: 300_000_000),
        EncoderPreset(
            id: "prores422", label: "ProRes 422", codec: .proRes422,
            pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, profile: nil, bitrate: nil),
        EncoderPreset(
            id: "prores422hq", label: "ProRes 422 HQ", codec: .proRes422HQ,
            pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, profile: nil, bitrate: nil),
        EncoderPreset(
            id: "prores4444", label: "ProRes 4444", codec: .proRes4444,
            pixelFormat: kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, profile: nil, bitrate: nil),
    ]

    /// HDR10's mastering display: P3-D65 primaries and a 1000-nit peak, as SEI's
    /// mastering_display_colour_volume, big-endian, green, blue then red, in 0.00002 steps, then
    /// white, then the peak and floor in 0.0001-nit steps.
    static let hdr10MasteringDisplay: Data = {
        var bytes = Data()
        func short(_ value: Double) { var v = UInt16((value / 0.00002).rounded()).bigEndian; withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) } }
        func long(_ value: UInt32) { var v = value.bigEndian; withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) } }
        for (x, y) in [(0.265, 0.69), (0.15, 0.06), (0.68, 0.32), (0.3127, 0.329)] {
            short(x)
            short(y)
        }
        long(10_000_000)
        long(1)
        return bytes
    }()

    /// HDR10's content light levels as SEI's content_light_level_info: MaxCLL then MaxFALL in
    /// whole nits, each a big-endian 16-bit value.
    static func contentLightLevel(maxCLL: Int, maxFALL: Int) -> Data {
        var bytes = Data()
        for value in [maxCLL, maxFALL] {
            var v = UInt16(clamping: max(value, 0)).bigEndian
            withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) }
        }
        return bytes
    }

    func outputSettings(
        width: Int, height: Int, frameRate: Double = 30, tag: FileTag = .rec2020, hdrMetadata: Bool = true,
        contentLight: (maxCLL: Int, maxFALL: Int)? = nil
    ) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            // The transfer tag is nominal: the real curve is recorded in the JSON sidecar.
            AVVideoColorPropertiesKey: tag.colorProperties,
        ]
        if let bitrate {
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoAllowFrameReorderingKey: false,
            ]
            if let profile { compression[AVVideoProfileLevelKey] = profile }
            if tag == .pq, codec == .hevc, hdrMetadata {
                compression[kVTCompressionPropertyKey_MasteringDisplayColorVolume as String] = Self.hdr10MasteringDisplay
                // Only export knows them, from a first pass over the take; live takes can't.
                if let contentLight {
                    compression[kVTCompressionPropertyKey_ContentLightLevelInfo as String] =
                        Self.contentLightLevel(maxCLL: contentLight.maxCLL, maxFALL: contentLight.maxFALL)
                }
            }
            // An HLG take failed on its first frame with -12902, a parameter the encoder refused,
            // where PQ wrote. Left to itself, the encoder makes its own HDR metadata for HLG,
            // so it's told not to; the tags still mark the file HLG.
            if tag == .hlg, codec == .hevc {
                compression[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] = kVTHDRMetadataInsertionMode_None
            }
            settings[AVVideoCompressionPropertiesKey] = compression
        }
        return settings
    }
}

public struct EncoderSize: Identifiable, Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var id: String { label }
    public var label: String { "\(width)x\(height)" }

    /// Center crop to 16:9 at the same width, kept to even dimensions.
    public var widescreen: EncoderSize {
        EncoderSize(width: width, height: (width * 9 / 16 + 1) & ~1)
    }

    public static let all = [
        EncoderSize(width: 4032, height: 3024),
        EncoderSize(width: 2880, height: 2160),
        EncoderSize(width: 1920, height: 1440),
    ]
}
