import Foundation
import VLCore

/// Describes the capture setup, supplied by the app when a recording starts.
public struct ClipContext: Codable, Sendable {
    public var method: String
    public var lens: String
    public var format: String
    public var requestedSeconds: Double

    public init(method: String, lens: String, format: String, requestedSeconds: Double) {
        self.method = method
        self.lens = lens
        self.format = format
        self.requestedSeconds = requestedSeconds
    }
}

public struct FrameRecord: Codable, Sendable {
    public var index: Int
    public var fileOffset: Int?
    public var pts: Double
    public var exposureSeconds: Double
    public var iso: Float
    public var whiteBalanceGains: [Float]
    public var sample: FrameSample?
}

/// Sparse pixel checks across the clip, showing the frames are real and on which scale.
public struct FrameCheck: Codable, Equatable, Sendable {
    public var sampledFrames = 0
    public var repeatedFrames = 0
    public var minValue: UInt16?
    public var maxValue: UInt16?
}

/// clip.json, written next to frames.raw when the recording finishes.
public struct ClipSidecar: Codable, Sendable {
    public var schema = 1
    public var device = SystemStatus.deviceModel
    public var osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    public var createdAt: String
    public var context: ClipContext
    public var layout: FrameLayout?
    public var bitsPerSample: Int?
    public var cfaPattern: String?
    /// Levels for frames.raw. They differ from `dng`, which holds the DNG file's own tags.
    public var blackLevel: [Double]?
    public var whiteLevel: [Double]?
    public var whiteBalanceGains: [Float]?
    public var colorMatrix1: [Double]?
    public var colorMatrix2: [Double]?
    public var dng: DNGMetadata?
    public var frameCheck: FrameCheck
    public var stats: FrameStats.Snapshot
    public var bytesWritten: Int
    public var writeThroughputMBps: Double
    public var peakPoolBlocks: Int
    public var poolLimitBlocks: Int
    public var errors: [String]
    public var frames: [FrameRecord]
}

public struct ClipResult: Sendable {
    public var directory: URL
    public var summary: String
    public var stats: FrameStats.Snapshot
}
