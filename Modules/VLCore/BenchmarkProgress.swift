import Foundation

/// Where this phone's benchmark stands, kept on disk after every step, per phone model and iOS
/// version. A step still marked running at launch means the app died in it: it's marked crashed,
/// logged, and skipped from then on. See docs/decisions/benchmark.md.
public struct BenchmarkProgress: Codable, Equatable, Sendable {
    public var device: String
    public var system: String
    public var results: [String: StepResult] = [:]
    /// The step under way, saved before it starts.
    public var running: String?
    public var startedAt: Date?
    public var finishedAt: Date?
    /// The owner said Later to the offer for this phone and iOS version.
    public var declined = false
    /// What each lens delivered, from the capture step.
    public var capture: [LensCapture] = []
    /// The least memory left and the most used while streaming at full size, in MB.
    public var memoryLeftMB: Int?
    public var memoryUsedMB: Int?

    public struct StepResult: Codable, Equatable, Sendable {
        /// "done", "failed", "skipped" or "crashed".
        public var status: String
        public var detail: String
        public var heat: String
        public var seconds: Double

        public init(status: String, detail: String, heat: String, seconds: Double) {
            self.status = status
            self.detail = detail
            self.heat = heat
            self.seconds = seconds
        }
    }

    public init(device: String, system: String) {
        self.device = device
        self.system = system
    }

    private enum CodingKeys: String, CodingKey {
        case device, system, results, running, startedAt, finishedAt, declined, capture, memoryLeftMB, memoryUsedMB
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        device = try values.decode(String.self, forKey: .device)
        system = try values.decode(String.self, forKey: .system)
        results = (try? values.decodeIfPresent([String: StepResult].self, forKey: .results)) ?? [:]
        running = try? values.decodeIfPresent(String.self, forKey: .running)
        startedAt = try? values.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try? values.decodeIfPresent(Date.self, forKey: .finishedAt)
        declined = (try? values.decodeIfPresent(Bool.self, forKey: .declined)) ?? false
        capture = (try? values.decodeIfPresent([LensCapture].self, forKey: .capture)) ?? []
        memoryLeftMB = try? values.decodeIfPresent(Int.self, forKey: .memoryLeftMB)
        memoryUsedMB = try? values.decodeIfPresent(Int.self, forKey: .memoryUsedMB)
    }

    public var finished: Bool { finishedAt != nil }

    /// The steps not yet settled, in order. A crashed or failed step counts as settled: the
    /// benchmark goes on without it rather than trying it again.
    public func pending(_ steps: [String]) -> [String] {
        steps.filter { results[$0] == nil }
    }

    public mutating func begin(_ step: String, at date: Date = Date()) {
        if startedAt == nil { startedAt = date }
        running = step
    }

    public mutating func finish(_ step: String, _ result: StepResult) {
        results[step] = result
        if running == step { running = nil }
    }

    /// At launch: a step left running means the app died in it. Returns that step.
    public mutating func noteCrash() -> String? {
        guard let step = running else { return nil }
        results[step] = StepResult(status: "crashed", detail: "the app stopped during this step", heat: "", seconds: 0)
        running = nil
        return step
    }

    /// One line per step, in a fixed form `tools/read_log.py` reads:
    /// `Benchmark: capture done in 64 s at nominal: 1x 30 fps, 0.5x 30 fps`
    public static func logLine(_ step: String, _ result: StepResult) -> String {
        String(format: "Benchmark: %@ %@ in %.0f s at %@: %@", step, result.status, result.seconds,
               result.heat.isEmpty ? "unknown heat" : result.heat, result.detail)
    }

    public static var file: URL { Storage.documents.appendingPathComponent("benchmark.json") }

    /// The saved progress for this phone and iOS version, or a fresh one: a new iOS measures again.
    public static func saved(device: String = SystemStatus.deviceModel,
                             system: String = ProcessInfo.processInfo.operatingSystemVersionString,
                             from url: URL = file) -> BenchmarkProgress {
        if let data = try? Data(contentsOf: url),
           let progress = try? JSONDecoder().decode(BenchmarkProgress.self, from: data),
           progress.device == device, progress.system == system {
            return progress
        }
        return BenchmarkProgress(device: device, system: system)
    }

    public func save(to url: URL = file) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// What one lens delivered while streaming, at the capture setup the phone settled on.
public struct LensCapture: Codable, Equatable, Sendable {
    public var lens: String
    /// The rate asked for, 30 or 24.
    public var frameRate: Double
    /// Unique frames a second that arrived.
    public var fps: Double
    public var missed: Int
    public var failures: Int
    public var setup: String

    public init(lens: String, frameRate: Double, fps: Double, missed: Int, failures: Int, setup: String) {
        self.lens = lens
        self.frameRate = frameRate
        self.fps = fps
        self.missed = missed
        self.failures = failures
        self.setup = setup
    }

    /// Within a frame a second of the rate asked for.
    public var holds: Bool { fps >= frameRate - 1 }

    /// The highest rate each lens held, by lens; 0 for a lens that held none.
    public static func bestRates(_ results: [LensCapture]) -> [String: Double] {
        var best: [String: Double] = [:]
        for result in results {
            let held = result.holds ? result.frameRate : 0
            best[result.lens] = max(best[result.lens] ?? 0, held)
        }
        return best
    }
}
