import Foundation

/// How the RAW photo stream is set up on one phone. Every phone starts on `standard`, the setup
/// proven on the iPhone 14 Pro, and only moves off it after its own stream has stalled, so one
/// phone's workaround never costs another phone heat or frame rate.
public struct CaptureSetup: Codable, Equatable, Sendable {
    /// Apple's preview stays on the session behind the Metal monitor, which costs heat.
    public var keepsPreview: Bool
    /// Zero shutter lag, responsive capture and fast capture prioritization.
    public var fastCapture: Bool
    /// One request at a time, instead of following the readiness coordinator.
    public var sequential: Bool

    public init(keepsPreview: Bool = false, fastCapture: Bool = true, sequential: Bool = false) {
        self.keepsPreview = keepsPreview
        self.fastCapture = fastCapture
        self.sequential = sequential
    }

    public static let standard = CaptureSetup()

    /// Tried in this order after a stall. The least costly change comes first, and the first one
    /// that streams is kept.
    public static let ladder: [CaptureSetup] = [
        .standard,
        CaptureSetup(keepsPreview: true),
        CaptureSetup(fastCapture: false),
        CaptureSetup(keepsPreview: true, fastCapture: false),
        CaptureSetup(keepsPreview: true, fastCapture: false, sequential: true),
    ]

    public var label: String {
        if self == .standard { return "standard" }
        var parts: [String] = []
        if keepsPreview { parts.append("Apple's preview connected") }
        if !fastCapture { parts.append("fast capture off") }
        if sequential { parts.append("sequential requests") }
        return parts.joined(separator: ", ")
    }
}

/// Which step of the ladder this phone streams on. Kept per phone model and iOS version, since
/// an iOS update can change the camera's behaviour either way.
public struct CaptureSupport: Codable, Equatable, Sendable {
    public var device: String
    public var system: String
    public var step: Int

    public init(device: String, system: String, step: Int = 0) {
        self.device = device
        self.system = system
        self.step = step
    }

    public static var file: URL { Storage.documents.appendingPathComponent("capture_support.json") }

    public var setup: CaptureSetup {
        CaptureSetup.ladder[min(max(step, 0), CaptureSetup.ladder.count - 1)]
    }

    /// The next step to try after a stall, or nil once every step has stalled.
    public var next: CaptureSupport? {
        guard step + 1 < CaptureSetup.ladder.count else { return nil }
        return CaptureSupport(device: device, system: system, step: step + 1)
    }

    public static func current() -> CaptureSupport {
        CaptureSupport(
            device: SystemStatus.deviceModel, system: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    /// The saved answer if it's for this phone and iOS version, or else the standard setup.
    public static func saved(from file: URL = CaptureSupport.file) -> CaptureSupport {
        let fresh = current()
        guard let data = try? Data(contentsOf: file),
            let support = try? JSONDecoder().decode(CaptureSupport.self, from: data),
            support.device == fresh.device, support.system == fresh.system,
            CaptureSetup.ladder.indices.contains(support.step)
        else { return fresh }
        return support
    }

    public func save(to file: URL = CaptureSupport.file) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: file, options: .atomic)
    }

    public static func forget(at file: URL = CaptureSupport.file) {
        try? FileManager.default.removeItem(at: file)
    }
}

/// Decides what a stalled photo loop does next. A single stall is retried in place, as before.
/// Stalls in a row with no frame between them mean the requests never finish, and firing more
/// only piles them up until the camera refuses with `-11830`. A stream that gives a frame now and
/// then between stalls is no better, so several stalls in a short while count the same.
public struct StallCounter: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case retry
        case giveUp
    }

    public private(set) var stallsWithoutFrame = 0
    private var recent: [Double] = []
    /// Stalls in a row, with no frame between, before giving up.
    public let limit: Int
    /// Stalls within `window` seconds before giving up, frames or not.
    public let windowLimit: Int
    public let window: Double

    public init(limit: Int = 2, windowLimit: Int = 4, window: Double = 20) {
        self.limit = limit
        self.windowLimit = windowLimit
        self.window = window
    }

    public mutating func frameArrived() {
        stallsWithoutFrame = 0
    }

    /// `time` is any clock in seconds that only moves forward.
    public mutating func stalled(at time: Double) -> Action {
        stallsWithoutFrame += 1
        recent = recent.filter { time - $0 < window } + [time]
        return stallsWithoutFrame >= limit || recent.count >= windowLimit ? .giveUp : .retry
    }

    public mutating func reset() {
        stallsWithoutFrame = 0
        recent = []
    }
}
