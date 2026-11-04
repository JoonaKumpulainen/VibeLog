import Foundation

/// A named copy of every setting, except the test link's and the presets themselves.
public struct FormatPreset: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var settings: AppConfig

    public var id: String { name }

    public init(name: String, settings: AppConfig) {
        self.name = name
        self.settings = settings.presetValues
    }

    private enum CodingKeys: String, CodingKey {
        case name, settings
        // Older presets kept these beside the name.
        case codec, size, widescreen, frameRate, logCurve, pipeline, debayer, exposureOffset, nativeGamut
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        if let saved = try? values.decode(AppConfig.self, forKey: .settings) {
            settings = saved.presetValues
            return
        }
        var older = AppConfig()
        older.codec = (try? values.decode(String.self, forKey: .codec)) ?? older.codec
        older.size = (try? values.decode(String.self, forKey: .size)) ?? older.size
        older.widescreen = (try? values.decode(Bool.self, forKey: .widescreen)) ?? older.widescreen
        older.frameRate = (try? values.decode(Double.self, forKey: .frameRate)) ?? older.frameRate
        older.logCurve = (try? values.decode(String.self, forKey: .logCurve)) ?? older.logCurve
        older.pipeline = (try? values.decode(String.self, forKey: .pipeline)) ?? older.pipeline
        older.debayer = (try? values.decode(String.self, forKey: .debayer)) ?? older.debayer
        older.exposureOffset = (try? values.decode(Double.self, forKey: .exposureOffset)) ?? older.exposureOffset
        older.nativeGamut = (try? values.decode(Bool.self, forKey: .nativeGamut)) ?? older.nativeGamut
        settings = older
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(settings, forKey: .settings)
    }
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
    /// Read only from older files, which had no gamut of their own.
    public var nativeGamut = false
    /// The recorded gamut's label. Empty in older files, which follow `nativeGamut`.
    public var gamut = ""
    /// Each curve records its own gamut, so either choice sets the other.
    public var pairsGamut = true
    /// Changes from the standard pairs, by label: curve to gamut, and gamut to curve.
    public var curveGamuts: [String: String] = [:]
    public var gamutCurves: [String: String] = [:]
    /// A viewfinder LUT for a curve in a gamut, keyed by `AppConfig.lutKey`.
    public var curveLUTs: [String: String] = [:]
    public var pipeline = "maximum"
    public var debayer = "Malvar-He-Cutler"
    public var exposureOffset = -0.5
    public var reduceLoadWhenHot = true
    public var bilinearWhenHot = false
    /// Stops the stream after this long with no touch. Zero never does.
    public var idlePauseMinutes = 2.0
    public var monitor = "rec709"
    public var monitorLUT = ""
    public var lutExpectsRec709 = false
    public var monitorOffWhileRecording = false
    public var telemetry = true
    public var lockAtRoll = true
    public var saveGyroLog = true
    public var pcmAudio = false
    /// Stereo from the built-in microphones.
    public var stereoAudio = true
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
    /// Lets the camera reshape frames to correct the lens. On, the ultra wide only reached 23 fps.
    public var distortionCorrection = false
    /// ProRes 4444 at 12 bits instead of 10.
    public var twelveBitProRes = false
    /// Records the viewfinder's look instead of log.
    public var bakeLook = false
    /// Baked takes record ProRes 422 HQ instead of HEVC 4:2:0.
    public var bakeToProRes = false
    /// The grade under the built-in looks and the Rec.709 view.
    public var lookGrade = LookGrade()
    /// Moves to the Efficient path while the phone is hot.
    public var efficientWhenHot = true
    public var frameGuide = "2.39"
    public var desqueeze = 1.0
    public var fileTag = "rec2020"
    /// Zebras or false color, kept in presets only. Written with `ExposureOverlay`'s raw values.
    public var overlay = 0
    /// Where the test link connects. It's never switched on from here.
    public var testServer = ""
    public var testToken = ""

    public init() {}

    /// A LUT belongs to a curve in one gamut, since a conversion LUT expects both.
    public static func lutKey(curve: String, gamut: String) -> String { "\(curve) · \(gamut)" }

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
        pairsGamut = read(.pairsGamut, defaults.pairsGamut)
        gamut = read(.gamut, defaults.gamut)
        curveGamuts = read(.curveGamuts, defaults.curveGamuts)
        gamutCurves = read(.gamutCurves, defaults.gamutCurves)
        curveLUTs = read(.curveLUTs, defaults.curveLUTs)
        pipeline = read(.pipeline, defaults.pipeline)
        debayer = read(.debayer, defaults.debayer)
        exposureOffset = read(.exposureOffset, defaults.exposureOffset)
        reduceLoadWhenHot = read(.reduceLoadWhenHot, defaults.reduceLoadWhenHot)
        bilinearWhenHot = read(.bilinearWhenHot, defaults.bilinearWhenHot)
        idlePauseMinutes = read(.idlePauseMinutes, defaults.idlePauseMinutes)
        monitor = read(.monitor, defaults.monitor)
        monitorLUT = read(.monitorLUT, defaults.monitorLUT)
        lutExpectsRec709 = read(.lutExpectsRec709, defaults.lutExpectsRec709)
        monitorOffWhileRecording = read(.monitorOffWhileRecording, defaults.monitorOffWhileRecording)
        telemetry = read(.telemetry, defaults.telemetry)
        lockAtRoll = read(.lockAtRoll, defaults.lockAtRoll)
        saveGyroLog = read(.saveGyroLog, defaults.saveGyroLog)
        pcmAudio = read(.pcmAudio, defaults.pcmAudio)
        stereoAudio = read(.stereoAudio, defaults.stereoAudio)
        mainsHz = read(.mainsHz, defaults.mainsHz)
        toolbar = read(.toolbar, defaults.toolbar)
        activeTools = read(.activeTools, defaults.activeTools)
        presets = read(.presets, defaults.presets)
        defaultPreset = read(.defaultPreset, defaults.defaultPreset)
        peakingSensitivity = read(.peakingSensitivity, defaults.peakingSensitivity)
        fixedFrameTime = read(.fixedFrameTime, defaults.fixedFrameTime)
        distortionCorrection = read(.distortionCorrection, defaults.distortionCorrection)
        twelveBitProRes = read(.twelveBitProRes, defaults.twelveBitProRes)
        bakeLook = read(.bakeLook, defaults.bakeLook)
        bakeToProRes = read(.bakeToProRes, defaults.bakeToProRes)
        lookGrade = read(.lookGrade, defaults.lookGrade)
        efficientWhenHot = read(.efficientWhenHot, defaults.efficientWhenHot)
        frameGuide = read(.frameGuide, defaults.frameGuide)
        desqueeze = read(.desqueeze, defaults.desqueeze)
        fileTag = read(.fileTag, defaults.fileTag)
        overlay = read(.overlay, defaults.overlay)
        testServer = read(.testServer, defaults.testServer)
        testToken = read(.testToken, defaults.testToken)
    }

    /// Nil when no default is set, or its preset is gone.
    public var startupPreset: FormatPreset? {
        presets.first { $0.name == defaultPreset }
    }

    /// These settings without what a preset leaves alone, so they can be saved and compared.
    public var presetValues: AppConfig {
        var values = self
        values.presets = []
        values.defaultPreset = ""
        values.testServer = ""
        values.testToken = ""
        return values
    }

    /// Takes all of a preset's settings, keeping the presets and the test link's address.
    public mutating func use(_ preset: FormatPreset) {
        var next = preset.settings
        next.presets = presets
        next.defaultPreset = defaultPreset
        next.testServer = testServer
        next.testToken = testToken
        self = next
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
