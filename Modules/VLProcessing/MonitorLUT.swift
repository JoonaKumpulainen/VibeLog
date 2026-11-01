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

/// Monitoring transform from log Rec.2020 to display Rec.709. It holds middle gray in
/// place and rolls highlights off, for judging exposure rather than as a finished look.
public enum MonitorTransform {
    /// Scene-linear value that reaches display white.
    private static let peak = 8.0
    private static let shoulderB = 0.82 * peak / (peak - 1)
    private static let shoulderA = 0.18 + shoulderB

    public static func display(log: SIMD3<Double>, curve: LogCurve) -> SIMD3<Double> {
        let linear2020 = SIMD3(curve.decode(log.x), curve.decode(log.y), curve.decode(log.z))
        let linear709 = ColorMath.rec2020ToRec709 * linear2020
        return SIMD3(tone(linear709.x), tone(linear709.y), tone(linear709.z))
    }

    private static func tone(_ value: Double) -> Double {
        let scene = max(value, 0)
        let shaped = min(shoulderA * scene / (scene + shoulderB), 1)
        return pow(shaped, 1 / 2.4)
    }

    /// RGBA samples for a cubic 3D texture in rgba16Unorm, with red varying fastest.
    public static func lut(curve: LogCurve, size: Int) -> [UInt16] {
        var samples = [UInt16]()
        samples.reserveCapacity(size * size * size * 4)
        let scale = 1 / Double(size - 1)
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let input = SIMD3(Double(red), Double(green), Double(blue)) * scale
                    let output = display(log: input, curve: curve)
                    samples.append(UInt16(output.x * 65535))
                    samples.append(UInt16(output.y * 65535))
                    samples.append(UInt16(output.z * 65535))
                    samples.append(65535)
                }
            }
        }
        return samples
    }
}
