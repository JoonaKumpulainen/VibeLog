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
    /// How `fps` was measured: the first launch's quick check, with the camera running and a few
    /// frames, under-reads by up to two and a half times on the 14 Pro; **Measure encoders again**
    /// stops the camera and encodes more.
    public var method = Method.quick
    /// The phone's heat when `fps` was measured, and when.
    public var heat = ""
    public var measuredAt: Date?
    /// Codecs and sizes, by preset ID and size label, a real take held 30 fps in with the encoder
    /// refusing nothing. A take outranks a trial, so these never warn.
    public var proven: [String: Set<String>] = [:]
    /// Codecs and sizes whose encoder refused frames in a real take. These always warn.
    public var strained: [String: Set<String>] = [:]

    public enum Method: String, Codable, Sendable {
        case quick = "quick check, camera running"
        case careful = "camera stopped"
    }

    public init(device: String, system: String, codecs: Set<String>, fps: [String: [String: Double]], measured: Bool) {
        self.device = device
        self.system = system
        self.codecs = codecs
        self.fps = fps
        self.measured = measured
    }

    private enum CodingKeys: String, CodingKey {
        case device, system, codecs, fps, measured, method, heat, measuredAt, proven, strained
    }

    /// Files from before `method` and the take evidence still read, as quick checks.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        device = try values.decode(String.self, forKey: .device)
        system = try values.decode(String.self, forKey: .system)
        codecs = try values.decode(Set<String>.self, forKey: .codecs)
        fps = try values.decode([String: [String: Double]].self, forKey: .fps)
        measured = try values.decode(Bool.self, forKey: .measured)
        method = (try? values.decodeIfPresent(Method.self, forKey: .method)) ?? .quick
        heat = (try? values.decodeIfPresent(String.self, forKey: .heat)) ?? ""
        measuredAt = try? values.decodeIfPresent(Date.self, forKey: .measuredAt)
        proven = (try? values.decodeIfPresent([String: Set<String>].self, forKey: .proven)) ?? [:]
        strained = (try? values.decodeIfPresent([String: Set<String>].self, forKey: .strained)) ?? [:]
    }

    /// What a real take showed about its encoder. Only a take of at least five seconds counts.
    public mutating func record(take key: String, size: String, seconds: Double, fps: Double, encoderDrops: Int) {
        guard seconds >= 5 else { return }
        if encoderDrops > 0 {
            strained[key, default: []].insert(size)
        } else if fps >= 29.5 {
            proven[key, default: []].insert(size)
        }
    }

    /// Why a take in this codec and size may drop frames, or nil when there's no reason to think
    /// so. A take that held outranks any trial; a take whose encoder refused frames outranks a
    /// trial that read fast.
    public func warning(for key: String, size: String) -> String? {
        if strained[key]?.contains(size) == true {
            return "This codec and size dropped frames at the encoder in an earlier take"
        }
        if proven[key]?.contains(size) == true { return nil }
        guard let rate = fps[key]?[size], rate < Self.realTimeFPS else { return nil }
        let how = method == .quick ? " in the quick check" : ""
        return String(format: "This codec and size encoded at %.0f fps on this phone%@, so frames may drop", rate, how)
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

    /// What a default needs over 30 fps. The trials run on a cool, idle phone, and a take shares
    /// it with the camera and the GPU, so a size that only just made 30 has nothing to spare.
    public static let comfortableFPS = 36.0

    /// The largest size the preset encoded with room to spare, or else the largest it encoded at
    /// 30 fps at all.
    public func defaultSize(for preset: EncoderPreset) -> (size: EncoderSize, comfortable: Bool)? {
        guard measured, let sizes = fps[preset.id] else { return nil }
        let tried = EncoderSize.all.filter { sizes[$0.label] != nil }
        if let size = tried.first(where: { sizes[$0.label]! >= Self.comfortableFPS }) { return (size, true) }
        if let size = tried.first(where: { sizes[$0.label]! >= Self.realTimeFPS }) { return (size, false) }
        return nil
    }

    private static func chroma(_ id: String) -> String {
        id.contains("444") ? "444" : id.contains("420") ? "420" : "422"
    }

    /// The codec and size a phone should start on, given the one the app would otherwise use. A
    /// phone that encodes it at full size with room to spare keeps it, so a phone with a fast
    /// ProRes encoder is never moved. Otherwise the most pixels win, since a small picture loses
    /// more than a codec change does: then room to spare, the wanted codec, its chroma, and the
    /// usual order. Nil before the trials, or when nothing reached 30 fps.
    public func bestDefault(for preset: EncoderPreset) -> (preset: EncoderPreset, size: EncoderSize)? {
        guard measured else { return nil }
        if let own = defaultSize(for: preset), own.comfortable, own.size == EncoderSize.all[0] {
            return (preset, own.size)
        }
        let order = ["prores422hq", "prores4444", "prores422", "hevc422", "hevc444", "hevc420"]
        var best: (preset: EncoderPreset, size: EncoderSize, score: [Double])?
        for (rank, id) in order.enumerated() {
            guard let candidate = EncoderPreset.all.first(where: { $0.id == id }), supports(candidate),
                let fit = defaultSize(for: candidate)
            else { continue }
            let score: [Double] = [
                Double(fit.size.width * fit.size.height), fit.comfortable ? 1 : 0,
                candidate.id == preset.id ? 1 : 0, Self.chroma(id) == Self.chroma(preset.id) ? 1 : 0,
                -Double(rank),
            ]
            if best.map({ $0.score.lexicographicallyPrecedes(score) }) ?? true {
                best = (candidate, fit.size, score)
            }
        }
        if let best { return (best.preset, best.size) }
        return bestSize(for: preset).map { (preset, $0) }
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
    public static func measure(frames: Int = 20, careful: Bool = false, completion: @escaping (EncoderSupport) -> Void) {
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
            support.method = careful ? .careful : .quick
            support.heat = SystemStatus.thermalName
            support.measuredAt = Date()
            lines.append("Measured \(support.method.rawValue), heat \(support.heat)")
            lines.forEach { Log.shared.info($0) }
            DispatchQueue.main.async { completion(support) }
        }
    }
}
