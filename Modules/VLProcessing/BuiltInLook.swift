import Foundation
import VLCore
import simd

/// Looks VibeLog makes itself rather than reads from a .cube file: the ACES 2.0 and ACES 1.3 Rec.709
/// output transforms, each built as a LUT on log for the curve and gamut recorded. Their names
/// don't end in .cube, so they can't clash with an imported LUT.
public enum BuiltInLook: String, CaseIterable, Sendable {
    case aces20 = "ACES 2.0"
    case aces13 = "ACES 1.3"

    public var name: String { rawValue }

    /// For the status line and the LOOK cell.
    public var shortLabel: String {
        switch self {
        case .aces20: return "ACES2"
        case .aces13: return "ACES13"
        }
    }

    public static func named(_ name: String) -> BuiltInLook? { BuiltInLook(rawValue: name) }

    /// Linear Rec.2020 to ACES2065-1, row-major, as OpenColorIO 2.6's ACES configs convert it,
    /// with Bradford adaptation from D65 to the ACES white.
    static let rec2020ToAP0: [Double] = [
        0.6790856122970581, 0.15770091116428375, 0.16321344673633575,
        0.04600200429558754, 0.859054684638977, 0.0949433222413063,
        -0.0005739431944675744, 0.02846776880323887, 0.9721061587333679,
    ]

    /// Display code values for a scene-linear Rec.2020 colour, as the OpenColorIO view
    /// "Rec.1886 Rec.709 - Display" shows it.
    public func display(linearRec2020 rgb: SIMD3<Double>, aces2: ACES2Renderer? = nil) -> SIMD3<Double> {
        let m = Self.rec2020ToAP0
        let ap0 = (m[0] * rgb.x + m[1] * rgb.y + m[2] * rgb.z,
                   m[3] * rgb.x + m[4] * rgb.y + m[5] * rgb.z,
                   m[6] * rgb.x + m[7] * rgb.y + m[8] * rgb.z)
        switch self {
        case .aces20:
            return (aces2 ?? ACES2Renderer.shared).display(ap0: ap0)
        case .aces13:
            let out = ACES13Output.forward(ap0)
            return SIMD3(out.0, out.1, out.2)
        }
    }

    /// The look as a LUT on the log image: each grid point is decoded with the curve, taken from
    /// the gamut to Rec.2020, graded, then through the transform. 65 points keeps interpolation small.
    public func lut(curve: LogCurve, gamut: Gamut, grade: LookGrade = LookGrade(), size: Int = 65) -> CubeLUT {
        let renderer = ACES2Renderer.shared
        return Self.makeLUT(curve: curve, gamut: gamut, grade: grade, size: size) {
            display(linearRec2020: $0, aces2: renderer)
        }
    }

    /// VibeLog's own Rec.709 view with a grade, as a LUT on log. Without a grade the view needs no
    /// LUT, since the GPU does its math per pixel.
    public static func rec709LUT(curve: LogCurve, gamut: Gamut, grade: LookGrade, size: Int = 65) -> CubeLUT {
        makeLUT(curve: curve, gamut: gamut, grade: grade, size: size, display: MonitorTransform.display(linearRec2020:))
    }

    /// An imported LUT with a grade under it, as one LUT on log, so the GPU still does one lookup.
    /// Each grid point is decoded, graded in scene-linear and encoded back to the curve, then,
    /// through the Rec.709 view if the LUT was made for it, looked up in the imported LUT. Grading
    /// past the top of the curve's range clips there, where ACES would roll it off.
    public static func graded(
        _ cube: CubeLUT, expectsRec709: Bool, curve: LogCurve, gamut: Gamut, grade: LookGrade, size: Int = 65
    ) -> CubeLUT {
        let fromRec2020 = gamut.fromRec2020
        return makeLUT(curve: curve, gamut: gamut, grade: grade, size: size) { linear in
            let native = fromRec2020 * linear
            func encode(_ value: Double) -> Double { min(max(curve.encode(max(value, 0)), 0), 1) }
            let log = SIMD3(encode(native.x), encode(native.y), encode(native.z))
            let input = expectsRec709 ? MonitorTransform.display(log: log, curve: curve, gamut: gamut) : log
            let out = cube.sample(SIMD3<Float>(Float(input.x), Float(input.y), Float(input.z)))
            return SIMD3(Double(out.x), Double(out.y), Double(out.z))
        }
    }

    private static func makeLUT(
        curve: LogCurve, gamut: Gamut, grade: LookGrade, size: Int,
        display: @escaping (SIMD3<Double>) -> SIMD3<Double>
    ) -> CubeLUT {
        let toRec2020 = gamut.fromRec2020.inverse
        let graded = GradeTransform(grade)
        let decoded = (0..<size).map { curve.decode(Double($0) / Double(size - 1)) }
        var samples = [SIMD3<Float>](repeating: .zero, count: size * size * size)
        samples.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: size) { blue in
                for green in 0..<size {
                    for red in 0..<size {
                        let linear = toRec2020 * SIMD3(decoded[red], decoded[green], decoded[blue])
                        let out = display(graded.apply(linear))
                        base[(blue * size + green) * size + red] = SIMD3(Float(out.x), Float(out.y), Float(out.z))
                    }
                }
            }
        }
        return CubeLUT(size: size, samples: samples)
    }
}

/// A `LookGrade` on scene-linear Rec.2020, in the order a colourist reaches for them: white
/// balance, exposure, contrast around middle gray, then saturation.
public struct GradeTransform: Sendable {
    public let grade: LookGrade
    private let whiteBalance: simd_double3x3

    /// Rec.2020's luminance weights.
    static let luma = SIMD3<Double>(0.2627, 0.6780, 0.0593)
    static let middleGray = 0.18

    public init(_ grade: LookGrade) {
        self.grade = grade
        whiteBalance = Self.whiteBalance(temperature: grade.temperature, tint: grade.tint)
    }

    public func apply(_ input: SIMD3<Double>) -> SIMD3<Double> {
        guard !grade.isNeutral else { return input }
        var rgb = whiteBalance * input * pow(2, grade.exposure)
        let y = simd_dot(rgb, Self.luma)
        if grade.contrast != 0, y > 0 {
            // A power around middle gray in luminance, so contrast doesn't also move saturation.
            let power = pow(2, grade.contrast * 0.6)
            rgb *= Self.middleGray * pow(y / Self.middleGray, power) / y
        }
        if grade.saturation != 1 {
            let graded = simd_dot(rgb, Self.luma)
            rgb = graded + grade.saturation * (rgb - graded)
        }
        return rgb
    }

    /// Bradford adaptation from a daylight white to D65's place, in Rec.2020. A warmer grade
    /// treats a bluer white as neutral, so the picture moves toward yellow, and tint moves the
    /// white off the daylight locus toward green, so the picture moves toward magenta.
    static func whiteBalance(temperature: Double, tint: Double) -> simd_double3x3 {
        guard temperature != 0 || tint != 0 else { return matrix_identity_double3x3 }
        let reference = daylightXYZ(mired: 1e6 / 6504, tint: 0)
        let source = daylightXYZ(mired: 1e6 / 6504 - temperature * 60, tint: tint)
        let toRec2020 = ColorMath.xyzToRec2020
        return toRec2020 * ColorMath.bradford(from: source, to: reference) * toRec2020.inverse
    }

    /// CIE daylight at a temperature, valid from 4000 to 25000 K, moved in CIE 1960 v by the tint.
    static func daylightXYZ(mired: Double, tint: Double) -> SIMD3<Double> {
        let t = 1e6 / mired
        let x = t <= 7000
            ? -4.6070e9 / (t * t * t) + 2.9678e6 / (t * t) + 0.09911e3 / t + 0.244063
            : -2.0064e9 / (t * t * t) + 1.9018e6 / (t * t) + 0.24748e3 / t + 0.237040
        let y = -3 * x * x + 2.870 * x - 0.275
        let d = -2 * x + 12 * y + 3
        let u = 4 * x / d
        let v = 6 * y / d + tint * 0.015
        let e = 2 * u - 8 * v + 4
        let (xx, yy) = (3 * u / e, 2 * v / e)
        return SIMD3(xx / yy, 1, (1 - xx - yy) / yy)
    }
}

/// The ACES 2.0 Rec.709 view as OpenColorIO builds it: clamp to AP1, the output transform with
/// Rec.709 limiting primaries at 100 nits, clamp to the display, then the Rec.1886 2.4 power.
public final class ACES2Renderer: @unchecked Sendable {
    /// Its tables take a moment to build, and never change.
    public static let shared = ACES2Renderer()

    let transform = ACES2OutputTransform()
    private static let ap0ToAP1 = ACES13Output.ap0ToAP1
    private static let ap1ToAP0 = ACES13Output.ap1ToAP0
    /// 8 x (128 + 768 x log(peak / 100) / log(100)), which is 1024 at 100 nits.
    private static let ap1UpperBound = 1024.0

    func display(ap0 input: (Double, Double, Double)) -> SIMD3<Double> {
        var ap1 = ACES13Output.mult(Self.ap0ToAP1, input)
        let bound = Self.ap1UpperBound
        ap1 = (min(max(ap1.0, 0), bound), min(max(ap1.1, 0), bound), min(max(ap1.2, 0), bound))
        let ap0 = ACES13Output.mult(Self.ap1ToAP0, ap1)
        let out = transform.forward((Float(ap0.0), Float(ap0.1), Float(ap0.2)))
        func encode(_ v: Float) -> Double { pow(Double(min(max(v, 0), 1)), 1 / 2.4) }
        return SIMD3(encode(out.0), encode(out.1), encode(out.2))
    }
}
