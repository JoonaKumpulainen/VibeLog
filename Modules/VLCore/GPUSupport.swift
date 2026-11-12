import Foundation

/// What this phone's GPU costs for each recording setup, and what real takes showed about them.
/// The GPU cost test times each setup in isolation; a take's own GPU time reads two to three times
/// that, and how far a setup can go depends on heat over minutes, so the time alone can't say
/// whether a take will hold. Takes decide: a long take that held proves its setup, and one that
/// fell behind on the GPU strains it. A setup only warns when a take strained it, or when it
/// costs more than anything a long take has held on this phone. With no takes yet, nothing warns.
/// Kept per phone and iOS version, as `EncoderSupport` is.
public struct GPUSupport: Codable, Equatable, Sendable {
    public var device: String
    public var system: String
    /// Median milliseconds per frame by setup key, from the GPU cost test.
    public var costs: [String: Double] = [:]
    public var heat = ""
    public var measuredAt: Date?
    /// Setups a take of `provingSeconds` or more held with almost nothing lost on the GPU.
    public var proven: Set<String> = []
    /// Setups whose take lost more than `strainedShare` of its frames on the GPU.
    public var strained: Set<String> = []

    public init(device: String, system: String) {
        self.device = device
        self.system = system
    }

    private enum CodingKeys: String, CodingKey {
        case device, system, costs, heat, measuredAt, proven, strained
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        device = try values.decode(String.self, forKey: .device)
        system = try values.decode(String.self, forKey: .system)
        costs = (try? values.decodeIfPresent([String: Double].self, forKey: .costs)) ?? [:]
        heat = (try? values.decodeIfPresent(String.self, forKey: .heat)) ?? ""
        measuredAt = try? values.decodeIfPresent(Date.self, forKey: .measuredAt)
        proven = (try? values.decodeIfPresent(Set<String>.self, forKey: .proven)) ?? []
        strained = (try? values.decodeIfPresent(Set<String>.self, forKey: .strained)) ?? []
    }

    /// Baked FX fell behind after about two minutes on the 14 Pro, so a take proves its setup
    /// only past that.
    public static let provingSeconds = 150.0
    /// A take that loses more than this share of its frames on the GPU strains its setup.
    public static let strainedShare = 0.01
    /// A take within this share of a proven setup's cost counts as no heavier.
    public static let costTolerance = 1.1

    /// A setup: the path, the work on top of the debayer, and the debayer.
    /// `path` is "maximum" or "efficient", `work` "log", "look" or "fx", `debayer` "malvar" or "bilinear".
    public static func key(path: String, work: String, debayer: String) -> String {
        "\(path)-\(work)-\(debayer)"
    }

    /// The cost test's stages that are whole recording setups, by the stage's words.
    static let stageWork: [(path: String, stage: String, work: String)] = [
        ("maximum", "debayer and planes, log", "log"),
        ("maximum", "debayer and planes with the look", "look"),
        ("maximum", "debayer, glow and planes with the look and FX", "fx"),
        ("efficient", "a log take, planes and the monitor image every other frame", "log"),
        ("efficient", "planes with the look", "look"),
        ("efficient", "a baked FX take as recorded, monitor image and glow every other frame", "fx"),
        // The same stage's name in reports from before 0.1.110.
        ("efficient", "a baked FX take, monitor image and glow every other frame", "fx"),
    ]

    /// Reads the cost test's report lines, such as
    /// `Maximum, Malvar-He-Cutler: debayer and planes, log, 17.6, 16.1 to 19.8`.
    public static func costs(fromReport lines: [String]) -> [String: Double] {
        var found: [String: Double] = [:]
        for line in lines {
            guard let colon = line.range(of: ": ") else { continue }
            let head = line[..<colon.lowerBound].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            var parts = line[colon.upperBound...].components(separatedBy: ", ")
            guard head.count == 2, parts.count >= 3, let median = Double(parts[parts.count - 2]) else { continue }
            parts.removeLast(2)
            let stage = parts.joined(separator: ", ")
            let path = head[0].lowercased()
            let debayer = head[1].lowercased().hasPrefix("malvar") ? "malvar" : head[1].lowercased()
            if let match = stageWork.first(where: { $0.path == path && $0.stage == stage }) {
                found[key(path: path, work: match.work, debayer: debayer)] = median
            }
        }
        return found
    }

    /// What a take showed about its setup.
    public mutating func record(take key: String, seconds: Double, frames: Int, gpuDropped: Int) {
        let total = frames + gpuDropped
        guard total > 0 else { return }
        let share = Double(gpuDropped) / Double(total)
        if share > Self.strainedShare, seconds >= 30 {
            strained.insert(key)
        } else if seconds >= Self.provingSeconds, share <= Self.strainedShare / 5 {
            proven.insert(key)
        }
    }

    /// Why this setup may fall behind on the GPU, or nil when nothing says so.
    public func warning(for key: String) -> String? {
        if strained.contains(key) { return "This setup fell behind on the GPU in an earlier take" }
        if proven.contains(key) { return nil }
        guard let cost = costs[key] else { return nil }
        let heaviestHeld = proven.compactMap { costs[$0] }.max()
        guard let heaviestHeld, cost > heaviestHeld * Self.costTolerance else { return nil }
        return String(format: "Heavier on the GPU than any setup a long take has held here (%.0f against %.0f ms), so it may fall behind when warm",
                      cost, heaviestHeld)
    }

    public static var file: URL { Storage.documents.appendingPathComponent("gpu_support.json") }

    /// The saved record for this phone and iOS version, or a new one.
    public static func saved(device: String = SystemStatus.deviceModel,
                             system: String = ProcessInfo.processInfo.operatingSystemVersionString) -> GPUSupport {
        if let data = try? Data(contentsOf: file),
           let support = try? JSONDecoder().decode(GPUSupport.self, from: data),
           support.device == device, support.system == system {
            return support
        }
        return GPUSupport(device: device, system: system)
    }

    public func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }
}
