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
    private let hasBands: Bool

    /// Rec.2020's luminance weights.
    static let luma = SIMD3<Double>(0.2627, 0.6780, 0.0593)
    static let middleGray = 0.18

    public init(_ grade: LookGrade) {
        self.grade = grade
        whiteBalance = Self.whiteBalance(temperature: grade.temperature, tint: grade.tint)
        hasBands = grade.bands.contains { !$0.isNeutral }
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
        if hasBands { rgb = applyBands(rgb) }
        return rgb
    }


    /// Oklab, from Björn Ottosson's published matrices: XYZ to cone response, then the cube
    /// roots to lightness and the two opponent axes.
    private static let xyzToLMS = simd_double3x3(rows: [
        SIMD3(0.8189330101, 0.3618667424, -0.1288597137),
        SIMD3(0.0329845436, 0.9293118715, 0.0361456387),
        SIMD3(0.0482003018, 0.2643662691, 0.6338517070),
    ])
    private static let lmsToLab = simd_double3x3(rows: [
        SIMD3(0.2104542553, 0.7936177850, -0.0040720468),
        SIMD3(1.9779984951, -2.4285922050, 0.4505937099),
        SIMD3(0.0259040371, 0.7827717662, -0.8086757660),
    ])
    private static let rec2020ToLMS = xyzToLMS * ColorMath.xyzToRec2020.inverse
    private static let lmsToRec2020 = rec2020ToLMS.inverse
    private static let labToLMS = lmsToLab.inverse

    /// Each band's centre in Oklab hue degrees, near the colour of its name, and how far either
    /// side it reaches. Neighbours overlap, so ranges blend without edges. Skin sits between red
    /// and orange, narrower.
    static let bandCentres: [Double] = [29, 56, 110, 142, 195, 264, 328, 50]
    static let bandWidths: [Double] = [45, 40, 50, 55, 55, 60, 55, 22]

    static func oklab(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let lms = rec2020ToLMS * rgb
        return lmsToLab * SIMD3(cbrt(lms.x), cbrt(lms.y), cbrt(lms.z))
    }

    /// Back from Oklab, for tests that make colours by hue and chroma.
    static func rec2020(oklab lab: SIMD3<Double>) -> SIMD3<Double> {
        let lms = labToLMS * lab
        return lmsToRec2020 * (lms * lms * lms)
    }

    private static func smoothstep(_ low: Double, _ high: Double, _ x: Double) -> Double {
        let t = min(max((x - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Hue and chroma move in Oklab, where equal steps look about equal, and luminance scales the
    /// light itself. Near-grays are left alone, so a colour push never tints white or black.
    private func applyBands(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let lab = Self.oklab(rgb)
        let chroma = (lab.y * lab.y + lab.z * lab.z).squareRoot()
        guard chroma > 1e-6 else { return rgb }
        let hue = atan2(lab.z, lab.y) * 180 / .pi
        let colourful = Self.smoothstep(0.01, 0.05, chroma)
        var shift = SIMD3<Double>()
        for band in ColorBand.allCases {
            let adjust = grade.bands[band.rawValue]
            guard !adjust.isNeutral else { continue }
            var distance = abs(hue - Self.bandCentres[band.rawValue]).truncatingRemainder(dividingBy: 360)
            if distance > 180 { distance = 360 - distance }
            let width = Self.bandWidths[band.rawValue]
            guard distance < width else { continue }
            var weight = pow(cos(.pi / 2 * distance / width), 2) * colourful
            if band == .skin { weight *= 1 - Self.smoothstep(0.10, 0.18, chroma) }
            shift += weight * SIMD3(adjust.hue, adjust.saturation, adjust.luminance)
        }
        guard shift != .zero else { return rgb }
        let turned = (hue + shift.x * 30) * .pi / 180
        let scaled = chroma * max(1 + shift.y, 0)
        let lms = Self.labToLMS * SIMD3(lab.x, scaled * cos(turned), scaled * sin(turned))
        return Self.lmsToRec2020 * (lms * lms * lms) * pow(2, shift.z)
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
    /// 1000 nits with P3-D65 limiting, as OpenColorIO's "ACES 2.0 - HDR 1000 nits (P3 D65)".
    public static let hdr = ACES2Renderer(peak: 1000, limiting: ACES2OutputTransform.p3d65)

    let transform: ACES2OutputTransform
    private static let ap0ToAP1 = ACES13Output.ap0ToAP1
    private static let ap1ToAP0 = ACES13Output.ap1ToAP0
    /// 8 x (128 + 768 x log(peak / 100) / log(100)), which is 1024 at 100 nits.
    private let ap1UpperBound: Double

    init(peak: Float = 100, limiting: ACES2OutputTransform.Primaries = ACES2OutputTransform.rec709) {
        transform = ACES2OutputTransform(peakLuminance: peak, limiting: limiting)
        ap1UpperBound = 8 * (128 + 768 * log10(Double(peak) / 100) / 2)
    }

    /// The transform's output, linear in its limiting primaries, where 1 is 100 nits.
    func displayLinear(ap0 input: (Double, Double, Double)) -> SIMD3<Double> {
        var ap1 = ACES13Output.mult(Self.ap0ToAP1, input)
        let bound = ap1UpperBound
        ap1 = (min(max(ap1.0, 0), bound), min(max(ap1.1, 0), bound), min(max(ap1.2, 0), bound))
        let ap0 = ACES13Output.mult(Self.ap1ToAP0, ap1)
        let out = transform.forward((Float(ap0.0), Float(ap0.1), Float(ap0.2)))
        return SIMD3(Double(out.0), Double(out.1), Double(out.2))
    }

    func display(ap0 input: (Double, Double, Double)) -> SIMD3<Double> {
        let out = displayLinear(ap0: input)
        func encode(_ v: Double) -> Double { pow(min(max(v, 0), 1), 1 / 2.4) }
        return SIMD3(encode(out.x), encode(out.y), encode(out.z))
    }
}

/// What a baked look records: the Rec.709 picture, or HDR as PQ for HDR10 or as HLG.
public enum BakeTarget: String, CaseIterable, Identifiable, Sendable {
    case sdr, pq, hlg

    public var id: String { rawValue }
    public var isHDR: Bool { self != .sdr }

    public var label: String {
        switch self {
        case .sdr: return "SDR Rec.709"
        case .pq: return "HDR PQ (HDR10)"
        case .hlg: return "HDR HLG"
        }
    }
}

/// PQ and HLG, from BT.2100, for ACES 2.0's 1000-nit picture in Rec.2020.
enum HDREncoding {
    static let peak = 1000.0

    static let p3ToRec2020: simd_double3x3 = {
        let m = ACES2OutputTransform.rgbToXYZ(ACES2OutputTransform.p3d65)
        let toXYZ = simd_double3x3(rows: [SIMD3(m[0], m[1], m[2]), SIMD3(m[3], m[4], m[5]), SIMD3(m[6], m[7], m[8])])
        return ColorMath.xyzToRec2020 * toXYZ
    }()

    /// SMPTE ST 2084, from display light in nits.
    static func pq(_ nits: SIMD3<Double>) -> SIMD3<Double> {
        func encode(_ value: Double) -> Double {
            let m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128
            let c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32
            let y = pow(min(max(value, 0), 10000) / 10000, m1)
            return pow((c1 + c2 * y) / (1 + c3 * y), m2)
        }
        return SIMD3(encode(nits.x), encode(nits.y), encode(nits.z))
    }

    /// HLG, from display light in nits on a 1000-nit display: back to scene light through the
    /// inverse of BT.2100's system gamma of 1.2, then the HLG curve.
    static func hlg(_ nits: SIMD3<Double>) -> SIMD3<Double> {
        let display = simd_clamp(nits / peak, SIMD3(repeating: 0), SIMD3(repeating: 1))
        let y = simd_dot(display, GradeTransform.luma)
        let scene = y > 0 ? display * pow(y, (1 - 1.2) / 1.2) : display
        func encode(_ e: Double) -> Double {
            let a = 0.17883277, b = 0.28466892, c = 0.55991073
            let value = min(max(e, 0), 1)
            return value <= 1.0 / 12 ? (3 * value).squareRoot() : a * log(12 * value - b) + c
        }
        return SIMD3(encode(scene.x), encode(scene.y), encode(scene.z))
    }
}

extension BuiltInLook {
    /// ACES 2.0's HDR look as a LUT on log, graded as the SDR one is, encoded as PQ or HLG in
    /// Rec.2020. Only ACES 2.0 has it: ACES 1.3's HDR outputs and imported LUTs stay SDR.
    public static func hdrLUT(
        curve: LogCurve, gamut: Gamut, grade: LookGrade = LookGrade(), target: BakeTarget, size: Int = 65
    ) -> CubeLUT {
        let renderer = ACES2Renderer.hdr
        return makeLUT(curve: curve, gamut: gamut, grade: grade, size: size) { linear in
            let m = rec2020ToAP0
            let ap0 = (m[0] * linear.x + m[1] * linear.y + m[2] * linear.z,
                       m[3] * linear.x + m[4] * linear.y + m[5] * linear.z,
                       m[6] * linear.x + m[7] * linear.y + m[8] * linear.z)
            let rec2020 = HDREncoding.p3ToRec2020 * renderer.displayLinear(ap0: ap0)
            let nits = simd_clamp(rec2020 * 100, SIMD3(repeating: 0), SIMD3(repeating: HDREncoding.peak))
            return target == .hlg ? HDREncoding.hlg(nits) : HDREncoding.pq(nits)
        }
    }
}
