import Foundation

/// A named set of recording choices, applied from Settings.
public struct FormatPreset: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var codec: String
    public var size: String
    public var widescreen: Bool
    public var frameRate: Double
    public var logCurve: String
    public var pipeline: String
    public var debayer: String
    public var exposureOffset: Double
    /// Missing from older presets.
    public var nativeGamut: Bool?

    public var id: String { name }

    public init(
        name: String, codec: String, size: String, widescreen: Bool, frameRate: Double,
        logCurve: String, pipeline: String, debayer: String, exposureOffset: Double,
        nativeGamut: Bool? = nil
    ) {
        self.name = name
        self.codec = codec
        self.size = size
        self.widescreen = widescreen
        self.frameRate = frameRate
        self.logCurve = logCurve
        self.pipeline = pipeline
        self.debayer = debayer
        self.exposureOffset = exposureOffset
        self.nativeGamut = nativeGamut
    }

    /// The app's own defaults. It's built in, so it can't be replaced or deleted.
    public static let stock: FormatPreset = {
        let defaults = AppConfig()
        return FormatPreset(
            name: "Stock", codec: defaults.codec, size: defaults.size, widescreen: defaults.widescreen,
            frameRate: defaults.frameRate, logCurve: defaults.logCurve, pipeline: defaults.pipeline,
            debayer: defaults.debayer, exposureOffset: defaults.exposureOffset,
            nativeGamut: defaults.nativeGamut)
    }()

    /// A saved preset can't take the built-in name.
    public static func isReserved(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(stock.name) == .orderedSame
    }

    public var isStock: Bool { Self.isReserved(name) }
}

/// Every saved choice, kept as readable JSON in the VibeLog folder. Missing keys take their
/// defaults, so files from older versions and hand edits keep working.
public struct AppConfig: Codable, Equatable, Sendable {
    public var codec = "prores422hq"
    public var size = "4032x3024"
    public var widescreen = false
    public var frameRate = 30.0
    public var stopAfterSeconds = 0.0
    public var logCurve = "Apple Log"
    public var nativeGamut = false
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
    public var saveGyroLog = true
    public var pcmAudio = false
    public var mainsHz = 50
    /// Tool identifiers, in toolbar order.
    public var toolbar = ["zebras", "falseColor", "grid", "center", "level", "punchIn"]
    /// Tools left on between sessions.
    public var activeTools: [String] = []
    public var presets: [FormatPreset] = []
    /// The preset the app opens with. Empty keeps the last choices used.
    public var defaultPreset = ""
    public var peakingSensitivity = "low"
    /// Holds the sensor at one frame time at 30 fps, as every other rate does.
    public var fixedFrameTime = true
    /// Lets the camera apply lens distortion correction, as it does by default.
    public var distortionCorrection = true
    /// Moves to the Efficient path while the phone is hot.
    public var efficientWhenHot = false
    public var frameGuide = "2.39"
    public var desqueeze = 1.0
    public var fileTag = "rec2020"
    /// Where the test link connects. It's never switched on from here.
    public var testServer = ""
    public var testToken = ""

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
        frameRate = read(.frameRate, defaults.frameRate)
        stopAfterSeconds = read(.stopAfterSeconds, defaults.stopAfterSeconds)
        logCurve = read(.logCurve, defaults.logCurve)
        nativeGamut = read(.nativeGamut, defaults.nativeGamut)
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
        saveGyroLog = read(.saveGyroLog, defaults.saveGyroLog)
        pcmAudio = read(.pcmAudio, defaults.pcmAudio)
        mainsHz = read(.mainsHz, defaults.mainsHz)
        toolbar = read(.toolbar, defaults.toolbar)
        activeTools = read(.activeTools, defaults.activeTools)
        // One saved or hand-edited under the built-in name keeps its choices under another.
        presets = read(.presets, defaults.presets).map { preset in
            var preset = preset
            if preset.isStock { preset.name = "My Stock" }
            return preset
        }
        defaultPreset = read(.defaultPreset, defaults.defaultPreset)
        peakingSensitivity = read(.peakingSensitivity, defaults.peakingSensitivity)
        fixedFrameTime = read(.fixedFrameTime, defaults.fixedFrameTime)
        distortionCorrection = read(.distortionCorrection, defaults.distortionCorrection)
        efficientWhenHot = read(.efficientWhenHot, defaults.efficientWhenHot)
        frameGuide = read(.frameGuide, defaults.frameGuide)
        desqueeze = read(.desqueeze, defaults.desqueeze)
        fileTag = read(.fileTag, defaults.fileTag)
        testServer = read(.testServer, defaults.testServer)
        testToken = read(.testToken, defaults.testToken)
    }

    /// Nil when no default is set, or its preset is gone.
    public var startupPreset: FormatPreset? {
        ([FormatPreset.stock] + presets).first { $0.name == defaultPreset }
    }

    /// Takes a preset's format choices and leaves every other setting.
    public mutating func use(_ preset: FormatPreset) {
        codec = preset.codec
        size = preset.size
        widescreen = preset.widescreen
        frameRate = preset.frameRate
        logCurve = preset.logCurve
        nativeGamut = preset.nativeGamut ?? false
        pipeline = preset.pipeline
        debayer = preset.debayer
        exposureOffset = preset.exposureOffset
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
