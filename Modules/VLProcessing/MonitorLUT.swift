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

/// Monitoring transform from log to display Rec.709. It holds middle gray in place, compresses
/// colours from outside Rec.709 into it, and rolls highlights off. The viewfinder does the same
/// math per pixel in `displayRec709`, rather than through a LUT, whose interpolation differed by
/// curve. A LUT made for Rec.709 gets this view first.
///
/// The gamut compression follows the ACES Reference Gamut Compression as OpenColorIO implements
/// it (ACES_GAMUT_COMP_13 in ops/fixedfunction/FixedFunctionOpCPU.cpp at commit 22dd9c4faa,
/// SPDX-License-Identifier: BSD-3-Clause, Copyright Contributors to the OpenColorIO Project; the
/// full terms are in LICENSES/OpenColorIO-BSD-3-Clause.txt), with ACES's thresholds and power.
/// Changes: applied in linear Rec.709 rather than AP1, with each channel's limit worked out from
/// how far the recorded gamut reaches outside Rec.709, so its most saturated colours land on
/// Rec.709's edge and colours well inside it are left alone.
public enum MonitorTransform {
    /// Scene-linear value that reaches display white.
    private static let peak = 8.0
    private static let shoulderB = 0.82 * peak / (peak - 1)
    private static let shoulderA = 0.18 + shoulderB

    /// Distances from neutral below these, for red, green and blue, are left alone: ACES's.
    public static let compressionThreshold = SIMD3<Double>(0.815, 0.803, 0.880)
    public static let compressionPower = 1.2

    /// How far each gamut's colours reach outside Rec.709, by channel, as the distance that
    /// compresses onto Rec.709's edge. 0 where the gamut stays inside, which turns that channel off.
    public static let gamutLimits: [Gamut: SIMD3<Double>] = {
        var limits: [Gamut: SIMD3<Double>] = [:]
        for gamut in Gamut.allCases { limits[gamut] = reach(of: gamut) }
        return limits
    }()

    /// The farthest distance from neutral along the gamut's edges, in Rec.709, by channel.
    static func reach(of gamut: Gamut) -> SIMD3<Double> {
        let matrix = ColorMath.rec2020ToRec709 * gamut.fromRec2020.inverse
        var farthest = SIMD3<Double>(repeating: 0)
        let corners = [SIMD3<Double>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        for index in 0..<3 {
            for step in 0...64 {
                let t = Double(step) / 64
                let colour = matrix * ((1 - t) * corners[index] + t * corners[(index + 1) % 3])
                let neutral = max(colour.x, colour.y, colour.z)
                guard neutral > 0 else { continue }
                farthest = simd_max(farthest, (SIMD3(repeating: neutral) - colour) / neutral)
            }
        }
        // A channel the gamut doesn't take past Rec.709's edge needs no compression.
        return SIMD3(farthest.x > 1 ? farthest.x : 0, farthest.y > 1 ? farthest.y : 0,
                     farthest.z > 1 ? farthest.z : 0)
    }

    /// The compression's scale for a limit, so the limit lands at a distance of 1.
    static func compressionScale(limit: Double, threshold: Double) -> Double {
        let power = compressionPower
        return (limit - threshold) / pow(pow((1 - threshold) / (limit - threshold), -power) - 1, 1 / power)
    }

    /// Each channel's compression scale for the gamut, 0 where it's off: what the GPU gets, in the
    /// fourth place of each Rec.709 matrix row.
    public static func compressionScales(_ gamut: Gamut) -> SIMD3<Double> {
        let limits = gamutLimits[gamut] ?? .zero
        return SIMD3((0..<3).map { limits[$0] > 0 ? compressionScale(limit: limits[$0], threshold: compressionThreshold[$0]) : 0 })
    }

    /// Linear Rec.709 with colours from outside it drawn in toward neutral, gently, as gamut_comp.
    public static func compressGamut(_ rgb: SIMD3<Double>, limits: SIMD3<Double>) -> SIMD3<Double> {
        let neutral = max(rgb.x, rgb.y, rgb.z)
        guard neutral != 0 else { return rgb }
        var out = rgb
        for channel in 0..<3 where limits[channel] > 0 {
            let threshold = compressionThreshold[channel]
            let distance = (neutral - rgb[channel]) / abs(neutral)
            guard distance >= threshold else { continue }
            let scale = compressionScale(limit: limits[channel], threshold: threshold)
            let normalized = (distance - threshold) / scale
            let compressed = threshold + scale * normalized
                / pow(1 + pow(normalized, compressionPower), 1 / compressionPower)
            out[channel] = neutral - compressed * abs(neutral)
        }
        return out
    }

    public static func display(log: SIMD3<Double>, curve: LogCurve, gamut: Gamut = .rec2020) -> SIMD3<Double> {
        let linear = SIMD3(curve.decode(log.x), curve.decode(log.y), curve.decode(log.z))
        return display(linearRec2020: gamut.fromRec2020.inverse * linear, gamut: gamut)
    }

    /// `gamut` is the one recorded, which sets how far the compression reaches.
    public static func display(linearRec2020 linear: SIMD3<Double>, gamut: Gamut = .rec2020) -> SIMD3<Double> {
        let linear709 = compressGamut(ColorMath.rec2020ToRec709 * linear, limits: gamutLimits[gamut] ?? .zero)
        return SIMD3(tone(linear709.x), tone(linear709.y), tone(linear709.z))
    }

    private static func tone(_ value: Double) -> Double {
        let scene = max(value, 0)
        let shaped = min(shoulderA * scene / (scene + shoulderB), 1)
        return pow(shaped, 1 / 2.4)
    }
}
