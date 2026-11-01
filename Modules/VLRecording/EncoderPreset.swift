import AVFoundation
import VideoToolbox

/// A codec and pixel format combination to try. Support varies by device, so the benchmark
/// tests these rather than assuming any of them works.
public struct EncoderPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let codec: AVVideoCodecType
    public let pixelFormat: OSType
    public let profile: String?
    public let bitrate: Int?

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

    func outputSettings(width: Int, height: Int) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            // The transfer tag is nominal: the real curve is recorded in the JSON sidecar.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ],
        ]
        if let bitrate {
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoAllowFrameReorderingKey: false,
            ]
            if let profile { compression[AVVideoProfileLevelKey] = profile }
            settings[AVVideoCompressionPropertiesKey] = compression
        }
        return settings
    }
}

public struct EncoderSize: Identifiable, Hashable, Sendable {
    public let width: Int
    public let height: Int

    public var id: String { label }
    public var label: String { "\(width)x\(height)" }

    public static let all = [
        EncoderSize(width: 4032, height: 3024),
        EncoderSize(width: 2880, height: 2160),
        EncoderSize(width: 1920, height: 1440),
    ]
}
