import AVFoundation
import VLCore

public enum CaptureMethod: String, CaseIterable, Identifiable, Sendable {
    case photoSequential
    case photoReadiness
    case photoBracket
    case videoData

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .photoSequential: return "Photo RAW: sequential"
        case .photoReadiness: return "Photo RAW: readiness/ZSL"
        case .photoBracket: return "Photo RAW: bracket burst"
        case .videoData: return "Video data output"
        }
    }

    public var isPhoto: Bool { self != .videoData }
}

public struct LensInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
}

public struct FormatInfo: Identifiable, Hashable, Sendable {
    public let id: Int
    public let label: String
    public let width: Int
    public let height: Int
    public let subtype: String
    public let maxFPS: Double
    public let maxPhotoWidth: Int
}

public struct PhotoSize: Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var label: String { "\(width)x\(height)" }
}

public struct CaptureConfig: Sendable {
    public var lensID: String
    public var formatIndex: Int
    public var method: CaptureMethod
    public var rawPixelFormat: OSType?
    public var photoSize: PhotoSize?
    public var videoPixelFormat: OSType?
    public var videoFPS: Double
    public var bracketCount: Int

    public init(
        lensID: String, formatIndex: Int, method: CaptureMethod, rawPixelFormat: OSType? = nil,
        photoSize: PhotoSize? = nil, videoPixelFormat: OSType? = nil, videoFPS: Double = 30,
        bracketCount: Int = 3
    ) {
        self.lensID = lensID
        self.formatIndex = formatIndex
        self.method = method
        self.rawPixelFormat = rawPixelFormat
        self.photoSize = photoSize
        self.videoPixelFormat = videoPixelFormat
        self.videoFPS = videoFPS
        self.bracketCount = bracketCount
    }
}

/// What the active configuration really offers, read back after configuring.
public struct CaptureOptions: Sendable {
    public var config: CaptureConfig
    public var formatDescription = ""
    public var rawPhotoTypes: [OSType] = []
    public var photoSizes: [PhotoSize] = []
    public var videoTypes: [OSType] = []
    public var maxBracketCount = 0
    public var isoRange: ClosedRange<Float> = 1...1
    public var shutterRange: ClosedRange<Double> = 1 / 8000...1
    public var maxWhiteBalanceGain: Float = 1
}

public enum ControlMode: Sendable {
    case auto
    case locked
}

extension AVCaptureDevice.Format {
    var fourCC: String {
        PixelFormats.fourCC(CMFormatDescriptionGetMediaSubType(formatDescription))
    }

    var maxFPS: Double {
        videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
    }

    var photoSizes: [PhotoSize] {
        supportedMaxPhotoDimensions.map { PhotoSize(width: Int($0.width), height: Int($0.height)) }
    }
}
