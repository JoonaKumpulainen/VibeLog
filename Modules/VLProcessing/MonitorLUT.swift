import Foundation
import simd

/// Log levels for exposure tools, in the same log space as the pipeline's output. Each is a
/// scene level relative to middle gray; the clip level is where the sensor saturates.
public struct MonitorBands: Equatable, Sendable {
    public var blueBelow: Float
    public var greenFrom: Float
    public var greenTo: Float
    public var pinkFrom: Float
    public var pinkTo: Float
    public var yellowFrom: Float
    public var clip: Float

    public init(curve: LogCurve, exposureStops: Double) {
        func level(_ stops: Double) -> Float { Float(curve.encode(0.18 * pow(2, stops))) }
        blueBelow = level(-4)
        greenFrom = level(-1.0 / 3)
        greenTo = level(1.0 / 3)
        pinkFrom = level(2.0 / 3)
        pinkTo = level(4.0 / 3)
        yellowFrom = level(5.0 / 3)
        clip = Float(curve.encode(0.98 * pow(2, exposureStops)))
    }
}

/// Monitoring transform from log to display Rec.709. It holds middle gray in place and rolls
/// highlights off, for judging exposure rather than as a finished look. The viewfinder does the
/// same math per pixel in `monitorDisplay`, rather than through a LUT, whose interpolation
/// differed by curve.
public enum MonitorTransform {
    /// Scene-linear value that reaches display white.
    private static let peak = 8.0
    private static let shoulderB = 0.82 * peak / (peak - 1)
    private static let shoulderA = 0.18 + shoulderB

    public static func display(log: SIMD3<Double>, curve: LogCurve, gamut: Gamut = .rec2020) -> SIMD3<Double> {
        let linear = SIMD3(curve.decode(log.x), curve.decode(log.y), curve.decode(log.z))
        let linear709 = ColorMath.rec2020ToRec709 * gamut.fromRec2020.inverse * linear
        return SIMD3(tone(linear709.x), tone(linear709.y), tone(linear709.z))
    }

    private static func tone(_ value: Double) -> Double {
        let scene = max(value, 0)
        let shaped = min(shoulderA * scene / (scene + shoulderB), 1)
        return pow(shaped, 1 / 2.4)
    }
}
