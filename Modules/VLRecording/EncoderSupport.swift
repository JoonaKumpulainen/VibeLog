import AVFoundation
import VLCore
import VideoToolbox

/// What this phone's encoders can do. Only the Pro iPhones from the 13 Pro on have a ProRes
/// encoder, and older chips may not encode every HEVC chroma at full size in real time, so the
/// app asks rather than assumes. Checked once per phone and iOS version, then kept.
public struct EncoderSupport: Codable, Equatable, Sendable {
    public var device: String
    public var system: String
    /// Presets whose codec VideoToolbox has an encoder for.
    public var codecs: Set<String>
    /// Frames a second each preset encoded at each size, by preset ID and size label. A size
    /// that was refused or failed has none. Empty until the trial encodes have run.
    public var fps: [String: [String: Double]]
    /// The trial encodes have run, so `fps` is the whole answer.
    public var measured: Bool

    public init(device: String, system: String, codecs: Set<String>, fps: [String: [String: Double]], measured: Bool) {
        self.device = device
        self.system = system
        self.codecs = codecs
        self.fps = fps
        self.measured = measured
    }

    /// The rate a take needs.
    public static let realTimeFPS = 30.0
    /// The 12-bit ProRes 4444 trial's key in `fps`, which shares 4444's preset ID.
    public static let twelveBitID = "prores4444-12"

    public static var file: URL { Storage.documents.appendingPathComponent("encoder_support.json") }

    /// Every preset a take or an export can use.
    public static var presets: [EncoderPreset] { EncoderPreset.all + [EncoderPreset.proRes422LT] }

    /// Whether this phone can record with the preset. Before the trials, a codec with an encoder
    /// counts.
    public func supports(_ preset: EncoderPreset) -> Bool {
        guard codecs.contains(preset.id) else { return false }
        guard measured else { return true }
        return !(fps[preset.id] ?? [:]).isEmpty
    }

    public var hasProRes: Bool { EncoderPreset.all.contains { $0.codec != .hevc && supports($0) } }

    /// 12-bit ProRes 4444 needs 4444 and its 16-bit input.
    public var supportsTwelveBit: Bool {
        guard let fourFour = EncoderPreset.all.first(where: { $0.id == "prores4444" }), supports(fourFour) else { return false }
        guard measured else { return true }
        return !(fps[Self.twelveBitID] ?? [:]).isEmpty
    }

    /// The largest size that encoded at 30 fps, or else the fastest one, or nil before the trials.
    public func bestSize(for preset: EncoderPreset) -> EncoderSize? {
        guard measured, let sizes = fps[preset.id], !sizes.isEmpty else { return nil }
        let tried = EncoderSize.all.filter { sizes[$0.label] != nil }
        return tried.first { sizes[$0.label]! >= Self.realTimeFPS }
            ?? tried.max { sizes[$0.label]! < sizes[$1.label]! }
    }

    /// The closest preset this phone records with: the same chroma first, then the most detail,
    /// and HEVC 4:2:0, which every phone has, when nothing is known to work.
    public func replacement(for preset: EncoderPreset) -> EncoderPreset {
        func chroma(_ id: String) -> String { id.contains("444") ? "444" : id.contains("420") ? "420" : "422" }
        let order = ["prores422hq", "prores4444", "prores422", "hevc422", "hevc444", "hevc420"]
        let ranked = order.compactMap { id in EncoderPreset.all.first { $0.id == id && supports($0) } }
        return ranked.first { chroma($0.id) == chroma(preset.id) } ?? ranked.first
            ?? EncoderPreset.all.first { $0.id == "hevc420" } ?? EncoderPreset.all[0]
    }

    public static var currentSystem: String { ProcessInfo.processInfo.operatingSystemVersionString }

    /// The saved answer, if it was measured on this phone and iOS version.
    public static func saved() -> EncoderSupport? {
        guard let data = try? Data(contentsOf: file),
            let support = try? JSONDecoder().decode(EncoderSupport.self, from: data),
            support.device == SystemStatus.deviceModel, support.system == currentSystem, support.measured
        else { return nil }
        return support
    }

    /// Which codecs have an encoder at all, which takes no time. It asks at 1080p, since an older
    /// encoder may refuse 12 MP and still record smaller sizes; the trials find which.
    public static func codecList() -> EncoderSupport {
        var codecs = Set<String>()
        var found: [CMVideoCodecType: Bool] = [:]
        for preset in presets {
            let type = codecType(preset.codec)
            if found[type] == nil {
                var properties: CFDictionary?
                var encoderID: CFString?
                let status = VTCopySupportedPropertyDictionaryForEncoder(
                    width: 1920, height: 1080, codecType: type, encoderSpecification: nil,
                    encoderIDOut: &encoderID, supportedPropertiesOut: &properties)
                found[type] = status == noErr
            }
            if found[type] == true { codecs.insert(preset.id) }
        }
        return EncoderSupport(
            device: SystemStatus.deviceModel, system: currentSystem, codecs: codecs, fps: [:], measured: false)
    }

    static func codecType(_ codec: AVVideoCodecType) -> CMVideoCodecType {
        switch codec {
        case .proRes422: return kCMVideoCodecType_AppleProRes422
        case .proRes422HQ: return kCMVideoCodecType_AppleProRes422HQ
        case .proRes422LT: return kCMVideoCodecType_AppleProRes422LT
        case .proRes4444: return kCMVideoCodecType_AppleProRes4444
        default: return kCMVideoCodecType_HEVC
        }
    }

    /// Keeps the answer, so the trials don't run again on this phone and iOS version.
    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }

    /// Encodes a few synthetic frames with each preset the codec list allows, largest size first,
    /// stopping at the first size that keeps 30 fps. Runs off the main thread, takes a few
    /// seconds, and calls back on the main queue without saving.
    public static func measure(frames: Int = 20, completion: @escaping (EncoderSupport) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var support = codecList()
            var lines = ["Encoder check on \(support.device), \(support.system)"]
            func run(_ preset: EncoderPreset, key: String, sizes: [EncoderSize]) {
                var results: [String: Double] = [:]
                for size in sizes {
                    let trial = EncoderProbe.trial(preset, size, frames: frames)
                    lines.append("\(key) \(size.label): " + (trial.problem ?? String(format: "%.1f fps", trial.fps)))
                    guard trial.problem == nil else { continue }
                    results[size.label] = trial.fps
                    if trial.fps >= realTimeFPS { break }
                }
                support.fps[key] = results
            }
            for preset in presets where support.codecs.contains(preset.id) {
                run(preset, key: preset.id, sizes: EncoderSize.all)
            }
            if let fourFour = EncoderPreset.all.first(where: { $0.id == "prores4444" }), support.codecs.contains(fourFour.id) {
                run(fourFour.twelveBit, key: twelveBitID, sizes: [EncoderSize.all[0]])
            }
            support.measured = true
            lines.forEach { Log.shared.info($0) }
            DispatchQueue.main.async { completion(support) }
        }
    }
}
