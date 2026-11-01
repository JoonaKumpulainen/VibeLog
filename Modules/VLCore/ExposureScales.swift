import Foundation

/// The values dials snap to. A stop's label is empty when it only needs a tick.
public enum ExposureScales {
    public struct Stop: Equatable, Sendable {
        public let value: Double
        public let label: String
        public let isMajor: Bool

        public init(value: Double, label: String, isMajor: Bool) {
            self.value = value
            self.label = label
            self.isMajor = isMajor
        }
    }

    /// One frame time is the longest exposure a frame rate allows.
    public static func slowestShutter(fps: Double) -> Double { fps }

    /// Third stops inside the lens's range, starting at its base ISO.
    public static func isoStops(range: ClosedRange<Double>) -> [Stop] {
        let thirds: [Double] = [
            100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000,
            5000, 6400, 8000, 10000, 12800,
        ]
        let full: Set<Double> = [100, 200, 400, 800, 1600, 3200, 6400, 12800]
        var stops = [Stop(value: range.lowerBound, label: "BASE", isMajor: true)]
        for iso in thirds where iso > range.lowerBound && iso < range.upperBound {
            stops.append(Stop(value: iso, label: "\(Int(iso))", isMajor: full.contains(iso)))
        }
        stops.append(Stop(value: range.upperBound, label: "\(Int(range.upperBound))", isMajor: true))
        return stops
    }

    /// Shutter denominators from one frame time upward. Flicker-safe stops for the mains
    /// frequency are the major ones.
    public static func shutterStops(fps: Double, mains: Int) -> [Stop] {
        let common: [Double] = [50, 60, 100, 120, 200, 250, 500, 1000, 2000, 4000, 8000]
        let safe = mains == 60 ? [60.0, 120.0] : [50.0, 100.0]
        let values = Set(common + [fps, fps * 2]).filter { $0 >= fps }
        return values.sorted().map {
            Stop(value: $0, label: "1/\(Int($0))", isMajor: safe.contains($0))
        }
    }

    public static func whiteBalanceStops() -> [Stop] {
        [2500, 2800, 3200, 4000, 5000, 5600, 6500, 7500, 9000].map {
            Stop(value: $0, label: "\(Int($0))", isMajor: $0 == 3200 || $0 == 5600)
        }
    }

    /// Lens position isn't a distance, so only its ends are named.
    public static func focusStops() -> [Stop] {
        (0...20).map { step in
            let label = step == 0 ? "NEAR" : step == 20 ? "FAR" : ""
            return Stop(value: Double(step) / 20, label: label, isMajor: step % 5 == 0)
        }
    }

    /// Even steps for fine adjustment, in ratios for ISO and shutter.
    public static func fineStops(geometric range: ClosedRange<Double>, perStop: Int) -> [Stop] {
        let count = Int((log2(range.upperBound / range.lowerBound) * Double(perStop)).rounded())
        let last = max(count, 1)
        return (0...last).map { step in
            let value = step == last ? range.upperBound : range.lowerBound * pow(2, Double(step) / Double(perStop))
            return Stop(value: value, label: "", isMajor: step % perStop == 0)
        }
    }

    public static func fineStops(linear range: ClosedRange<Double>, step: Double, majorEvery: Int) -> [Stop] {
        let count = Int(((range.upperBound - range.lowerBound) / step).rounded())
        return (0...count).map { index in
            Stop(value: range.lowerBound + Double(index) * step, label: "", isMajor: index % majorEvery == 0)
        }
    }

    /// Where a value sits along stops sorted by value, between their indexes.
    public static func position(of value: Double, in stops: [Stop]) -> Double {
        guard let first = stops.first, let last = stops.last, stops.count > 1 else { return 0 }
        guard value > first.value else { return 0 }
        guard value < last.value else { return Double(stops.count - 1) }
        let upper = stops.firstIndex { $0.value >= value } ?? stops.count - 1
        let low = stops[upper - 1].value
        let high = stops[upper].value
        return Double(upper - 1) + (value - low) / (high - low)
    }
}
