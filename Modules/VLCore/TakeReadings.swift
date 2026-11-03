import Foundation

/// What the camera reported for exposure and white balance during a take, sampled about once a
/// second, so the sidecar can say what a frozen take held and what an auto take ranged over.
public struct TakeReadings: Equatable, Sendable {
    /// How a value behaved during the take.
    public enum Mode: String, Sendable {
        case frozen = "frozen at start"
        case manual
        case auto
    }

    private var seconds: ClosedRange<Double>?
    private var iso: ClosedRange<Float>?
    private var temperature: ClosedRange<Float>?
    private var tint: Float?

    public init() {}

    public mutating func add(seconds: Double, iso: Float, temperature: Float?, tint: Float?) {
        if seconds > 0 { self.seconds = Self.widen(self.seconds, seconds) }
        if iso > 0 { self.iso = Self.widen(self.iso, iso) }
        if let temperature, temperature > 0 { self.temperature = Self.widen(self.temperature, temperature) }
        if self.tint == nil { self.tint = tint }
    }

    private static func widen<T: Comparable>(_ range: ClosedRange<T>?, _ value: T) -> ClosedRange<T> {
        guard let range else { return value...value }
        return min(range.lowerBound, value)...max(range.upperBound, value)
    }

    /// Such as "1/50 s, frozen at start" or "auto, 1/50 to 1/120 s".
    public func shutter(_ mode: Mode) -> String {
        guard let seconds else { return mode.rawValue }
        // A longer exposure is the smaller fraction, so the range reads from slow to fast.
        func label(_ value: Double) -> String { "1/\(Int((1 / value).rounded()))" }
        return Self.describe(label(seconds.upperBound), label(seconds.lowerBound), unit: "s", mode: mode)
    }

    public func isoText(_ mode: Mode) -> String {
        guard let iso else { return mode.rawValue }
        return Self.describe(
            "ISO \(Int(iso.lowerBound.rounded()))", "\(Int(iso.upperBound.rounded()))", unit: nil, mode: mode)
    }

    public func whiteBalance(_ mode: Mode) -> String {
        guard let temperature else { return mode.rawValue }
        let tintText = tint.map { String(format: ", tint %+.0f", $0) } ?? ""
        let text = Self.describe(
            "\(Int(temperature.lowerBound.rounded()))", "\(Int(temperature.upperBound.rounded()))", unit: "K",
            mode: mode)
        return mode == .auto ? text : text.replacingOccurrences(of: " K,", with: " K\(tintText),")
    }

    /// One value when it held, a range when it moved, with the mode first only for auto.
    private static func describe(_ low: String, _ high: String, unit: String?, mode: Mode) -> String {
        let suffix = unit.map { " \($0)" } ?? ""
        let value = low.hasSuffix(high) || low == high ? "\(low)\(suffix)" : "\(low) to \(high)\(suffix)"
        return mode == .auto ? "auto, \(value)" : "\(value), \(mode.rawValue)"
    }
}
