import Foundation

/// Every saved choice, kept as readable JSON in the VibeLog folder. Missing keys take their
/// defaults, so files from older versions and hand edits keep working.
public struct AppConfig: Codable, Equatable, Sendable {
    public var codec = "prores422hq"
    public var size = "4032x3024"
    public var widescreen = false
    public var stopAfterSeconds = 0.0
    public var logCurve = "Apple Log"
    public var pipeline = "maximum"
    public var debayer = "Malvar-He-Cutler"
    public var exposureOffset = -0.5
    public var reduceLoadWhenHot = true
    public var monitor = "rec709"
    public var monitorLUT = ""
    public var lutExpectsRec709 = false
    public var monitorOffWhileRecording = false
    public var telemetry = true
    public var lockAtRoll = true
    public var mainsHz = 50
    /// Tool identifiers, in toolbar order.
    public var toolbar = ["zebras", "falseColor", "grid", "center", "level", "punchIn"]
    /// Tools left on between sessions.
    public var activeTools: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            // One mistyped value must not discard the rest of the file.
            ((try? values.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        codec = read(.codec, defaults.codec)
        size = read(.size, defaults.size)
        widescreen = read(.widescreen, defaults.widescreen)
        stopAfterSeconds = read(.stopAfterSeconds, defaults.stopAfterSeconds)
        logCurve = read(.logCurve, defaults.logCurve)
        pipeline = read(.pipeline, defaults.pipeline)
        debayer = read(.debayer, defaults.debayer)
        exposureOffset = read(.exposureOffset, defaults.exposureOffset)
        reduceLoadWhenHot = read(.reduceLoadWhenHot, defaults.reduceLoadWhenHot)
        monitor = read(.monitor, defaults.monitor)
        monitorLUT = read(.monitorLUT, defaults.monitorLUT)
        lutExpectsRec709 = read(.lutExpectsRec709, defaults.lutExpectsRec709)
        monitorOffWhileRecording = read(.monitorOffWhileRecording, defaults.monitorOffWhileRecording)
        telemetry = read(.telemetry, defaults.telemetry)
        lockAtRoll = read(.lockAtRoll, defaults.lockAtRoll)
        mainsHz = read(.mainsHz, defaults.mainsHz)
        toolbar = read(.toolbar, defaults.toolbar)
        activeTools = read(.activeTools, defaults.activeTools)
    }

    public static func load(from url: URL) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
