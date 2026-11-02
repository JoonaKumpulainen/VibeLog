import Foundation

/// Times each step of the photo loop during a take, to show where a frame is lost: a request
/// sent late, or one the camera sat on. Entries stay in memory until the take ends, so saving
/// them can't change the timing being measured.
public final class CaptureTimingLog {
    public enum Event: String, Sendable {
        case request
        case willCapture = "will_capture"
        case frame
        case failed
        case finished
        case ready
        case notReady = "not_ready"
        /// The loop wanted to send a request and the camera wasn't ready.
        case heldNotReady = "held_not_ready"
        /// The loop wanted to send a request and all of them were in flight.
        case heldInFlight = "held_in_flight"
    }

    public struct Entry: Equatable, Sendable {
        public var event: Event
        /// Host clock seconds.
        public var time: Double
        /// The photo request, or 0 for events that don't belong to one.
        public var request: Int64
        /// The sensor's timestamp, on `frame` only.
        public var sensorTime: Double?
        /// Requests in flight, on `request` only.
        public var inFlight: Int?
    }

    /// About half an hour of a 30 fps take.
    public static let capacity = 400_000

    private let lock = NSLock()
    private var active = false
    private var entries: [Entry] = []

    public init() {}

    public func begin() {
        lock.lock()
        defer { lock.unlock() }
        entries = []
        entries.reserveCapacity(100_000)
        active = true
    }

    /// Ends the log and hands back what it holds, which is nothing if it wasn't running.
    public func finish() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        active = false
        let result = entries
        entries = []
        return result
    }

    public func record(
        _ event: Event, time: Double, request: Int64 = 0, sensorTime: Double? = nil, inFlight: Int? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard active, entries.count < Self.capacity else { return }
        entries.append(Entry(
            event: event, time: time, request: request, sensorTime: sensorTime, inFlight: inFlight))
    }

    /// One row per event. `seconds` counts from the first event.
    public static func csv(_ entries: [Entry]) -> String {
        let start = entries.first?.time ?? 0
        var text = "seconds,event,request,sensor_seconds,in_flight\n"
        for entry in entries {
            let sensor = entry.sensorTime.map { String(format: "%.6f", $0 - start) } ?? ""
            let inFlight = entry.inFlight.map { String($0) } ?? ""
            text += String(format: "%.6f", entry.time - start)
                + ",\(entry.event.rawValue),\(entry.request),\(sensor),\(inFlight)\n"
        }
        return text
    }

    /// A line for the session log, so a take can be read without opening the file.
    public static func summary(_ entries: [Entry]) -> String {
        var requested: [Int64: Double] = [:]
        var requestToCapture: [Double] = []
        var requestToFrame: [Double] = []
        var sensorTimes: [Double] = []
        var notReadySince: Double?
        var notReadySpans: [Double] = []
        var heldNotReady = 0
        var heldInFlight = 0
        var requests = 0
        var failures = 0

        for entry in entries {
            switch entry.event {
            case .request:
                requests += 1
                requested[entry.request] = entry.time
            case .willCapture:
                if let start = requested[entry.request] { requestToCapture.append(entry.time - start) }
            case .frame:
                if let start = requested[entry.request] { requestToFrame.append(entry.time - start) }
                if let sensorTime = entry.sensorTime { sensorTimes.append(sensorTime) }
            case .failed:
                failures += 1
            case .notReady:
                notReadySince = notReadySince ?? entry.time
            case .ready:
                if let start = notReadySince { notReadySpans.append(entry.time - start) }
                notReadySince = nil
            case .heldNotReady:
                heldNotReady += 1
            case .heldInFlight:
                heldInFlight += 1
            case .finished:
                break
            }
        }

        let gaps = zip(sensorTimes.sorted().dropFirst(), sensorTimes.sorted()).map { $0 - $1 }
        return "Capture timing: \(requests) requests, \(sensorTimes.count) frames, \(failures) failed, "
            + "request to capture \(milliseconds(requestToCapture)), "
            + "request to frame \(milliseconds(requestToFrame)), "
            + "not ready \(notReadySpans.count) times for \(milliseconds(notReadySpans)), "
            + "held \(heldNotReady) not ready and \(heldInFlight) in flight, frame gaps \(histogram(gaps))"
            + (entries.count >= capacity ? ", log full" : "")
    }

    private static func milliseconds(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "-" }
        return String(format: "%.1f ms median", values.sorted()[values.count / 2] * 1000)
    }

    /// The commonest gaps, to the nearest 5 ms so that 33 and 34 ms read as one.
    private static func histogram(_ gaps: [Double]) -> String {
        guard !gaps.isEmpty else { return "-" }
        let counts = Dictionary(grouping: gaps) { Int(($0 * 200).rounded()) * 5 }.mapValues(\.count)
        return counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(5)
            .map { "\($0.key) ms x\($0.value)" }.joined(separator: ", ")
    }
}
