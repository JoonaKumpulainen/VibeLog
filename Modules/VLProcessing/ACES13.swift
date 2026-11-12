// Ported to Swift from OpenColorIO's built-in ACES 1.x output transform at commit 22dd9c4faa:
// "ACES-OUTPUT - ACES2065-1_to_CIE-XYZ-D65 - SDR-VIDEO_1.0" in transforms/builtins/ACES.cpp, the
// ACES_GLOW_10, ACES_RED_MOD_10 and ACES_DARK_TO_DIM_10 renderers in
// ops/fixedfunction/FixedFunctionOpCPU.cpp, and the RGB curve fitting and evaluation in
// ops/gradingrgbcurve/GradingBSplineCurve.cpp, all of which carry:
//
//   SPDX-License-Identifier: BSD-3-Clause
//   Copyright Contributors to the OpenColorIO Project.
//
//   Redistribution and use in source and binary forms, with or without modification, are
//   permitted provided that the following conditions are met:
//   * Redistributions of source code must retain the above copyright notice, this list of
//     conditions and the following disclaimer.
//   * Redistributions in binary form must reproduce the above copyright notice, this list of
//     conditions and the following disclaimer in the documentation and/or other materials
//     provided with the distribution.
//   * Neither the name of the copyright holder nor the names of its contributors may be used to
//     endorse or promote products derived from this software without specific prior written
//     permission.
//
//   The full terms, with the disclaimer, are in LICENSES/OpenColorIO-BSD-3-Clause.txt.
//
// Changes from the original: translated from C++ to Swift in Double, with only the forward path of
// the SDR video view kept, followed by the Rec.1886 Rec.709 display from Displays.cpp, clamped to
// the display.

import Foundation

/// ACES 1.3's Rec.709 view, as OpenColorIO's "ACES 1.0 - SDR Video" builds it: the RRT's glow and
/// red modifier, its tone curve and the 48-nit ODT curve as fitted B-splines, the dark-to-dim
/// surround and desaturation for 100 nits, then Rec.709 with the 2.4 power. ACES2065-1 in,
/// Rec.1886 code values out.
enum ACES13Output {
    typealias M33 = [Double]

    // MARK: Matrices, in column-vector form

    static let ap0ToXYZ = ACES2OutputTransform.rgbToXYZ(ACES2OutputTransform.ap0)
    static let ap1ToXYZ = ACES2OutputTransform.rgbToXYZ(ACES2OutputTransform.ap1)
    static let xyzToAP1 = ACES2OutputTransform.invert(ap1ToXYZ)
    static let ap0ToAP1 = ACES2OutputTransform.multiply(xyzToAP1, ap0ToXYZ)
    static let ap1ToAP0 = ACES2OutputTransform.invert(ap0ToAP1)
    static let xyzToRec709 = ACES2OutputTransform.invert(ACES2OutputTransform.rgbToXYZ(ACES2OutputTransform.rec709))

    /// Bradford adaptation from the ACES white to D65.
    static let d60ToD65: M33 = {
        let bradford: M33 = [0.8951, 0.2664, -0.1614, -0.7502, 1.7135, 0.0367, 0.0389, -0.0685, 1.0296]
        func xyz(_ x: Double, _ y: Double) -> [Double] { [x / y, 1, (1 - x - y) / y] }
        func apply(_ m: M33, _ v: [Double]) -> [Double] {
            (0..<3).map { m[$0 * 3] * v[0] + m[$0 * 3 + 1] * v[1] + m[$0 * 3 + 2] * v[2] }
        }
        let src = apply(bradford, xyz(0.32168, 0.33767))
        let dst = apply(bradford, xyz(0.3127, 0.329))
        let scale: M33 = [dst[0] / src[0], 0, 0, 0, dst[1] / src[1], 0, 0, 0, dst[2] / src[2]]
        return ACES2OutputTransform.multiply(
            ACES2OutputTransform.invert(bradford), ACES2OutputTransform.multiply(scale, bradford))
    }()

    /// AP1 to CIE XYZ D65 with Bradford, then XYZ to Rec.709 with no adaptation, as the view and
    /// the display do it.
    static let ap1ToRec709 = ACES2OutputTransform.multiply(
        xyzToRec709, ACES2OutputTransform.multiply(d60ToD65, ap1ToXYZ))

    /// RRT_SAT_MAT in Generate_RRT_preamble_ops.
    static let rrtSatMatrix: M33 = [
        0.970889148671, 0.026963270632, 0.002147580696,
        0.010889148671, 0.986963270632, 0.002147580696,
        0.010889148671, 0.026963270632, 0.962147580696,
    ]

    /// DESAT_100_NITS in Generate_video_adjustment_ops.
    static let desat100Nits: M33 = [
        0.949056010175, 0.047185723607, 0.003758266219,
        0.019056010175, 0.977185723607, 0.003758266219,
        0.019056010175, 0.047185723607, 0.933758266219,
    ]

    @inline(__always) static func mult(_ m: M33, _ v: (Double, Double, Double)) -> (Double, Double, Double) {
        (m[0] * v.0 + m[1] * v.1 + m[2] * v.2,
         m[3] * v.0 + m[4] * v.1 + m[5] * v.2,
         m[6] * v.0 + m[7] * v.1 + m[8] * v.2)
    }

    // MARK: Glow and red modifier, from FixedFunctionOpCPU.cpp

    static let noiseLimit = 1e-2

    /// CalcSatWeight.
    static func satWeight(_ r: Double, _ g: Double, _ b: Double) -> Double {
        let lo = min(r, g, b)
        let hi = max(r, g, b)
        return (max(1e-10, hi) - max(1e-10, lo)) / max(noiseLimit, hi)
    }

    /// Renderer_ACES_Glow03_Fwd with ACES 1.0's gain 0.05 and mid 0.08.
    static func glow(_ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        let (r, g, b) = rgb
        let glowGain = 0.05, glowMid = 0.08
        let yc = (b + g + r + 1.75 * (b * (b - g) + g * (g - r) + r * (r - b)).squareRoot()) / 3
        let x = (satWeight(r, g, b) - 0.4) * 5
        let sign: Double = x.sign == .minus ? -1 : 1
        let t = max(0, 1 - 0.5 * sign * x)
        let gain = glowGain * (1 + sign * (1 - t * t)) * 0.5
        let out: Double
        if yc >= glowMid * 2 {
            out = 0
        } else if yc <= glowMid * 2 / 3 {
            out = gain
        } else {
            out = gain * (glowMid / yc - 0.5)
        }
        let added = 1 + out
        return (r * added, g * added, b * added)
    }

    /// Renderer_ACES_RedMod10_Fwd, with CalcHueWeight.
    static func redModifier(_ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        var r = rgb.0
        let g = rgb.1, b = rgb.2
        let invWidth = 1.6976527263135504
        let hue = atan2(3.0.squareRoot() * (g - b), 2 * r - (g + b))
        let knotCoord = hue * invWidth + 2
        let j = Int(knotCoord)
        var weight = 0.0
        if j >= 0 && j < 4 {
            let M: [[Double]] = [
                [0.25, 0, 0, 0],
                [-0.75, 0.75, 0.75, 0.25],
                [0.75, -1.5, 0, 1],
                [-0.25, 0.75, -0.75, 0.25],
            ]
            let t = knotCoord - Double(j)
            let c = M[j]
            weight = c[3] + t * (c[2] + t * (c[1] + t * c[0]))
        }
        if weight > 0 {
            r += weight * satWeight(r, g, b) * (0.03 - r) * (1 - 0.82)
        }
        return (r, g, b)
    }

    // MARK: Tone curves, from GradingBSplineCurve.cpp

    /// A curve fitted from control points and slopes as piecewise quadratics in log10.
    struct Curve {
        var knots: [Double] = []
        var a: [Double] = []
        var b: [Double] = []
        var c: [Double] = []

        /// computeKnotsAndCoefsForRGBCurve with the slopes given: FitRGBSpline, then
        /// AdjustRGBSlopes and a second fit if any segment would dip.
        init(points: [(x: Double, y: Double)], slopes given: [Double]) {
            var slopes = given
            fit(points, slopes)
            var adjusted = false
            var i = 0
            for ksi in knots {
                guard points[i].x != ksi else { continue }
                let (xi, yi) = points[i]
                let (x1, y1) = points[i + 1]
                let sBar = (2 * (y1 - yi) - (ksi - xi) * slopes[i] - (x1 - ksi) * slopes[i + 1]) / (x1 - xi)
                if sBar < 0 {
                    adjusted = true
                    let secant = (y1 - yi) / (x1 - xi)
                    let blend = ((ksi - xi) * slopes[i] + (x1 - ksi) * slopes[i + 1]) / (x1 - xi)
                    let aim = min(0.01 * 0.5 * (slopes[i] + slopes[i + 1]), secant)
                    let adjust = (2 * secant - aim) / blend
                    slopes[i] *= adjust
                    slopes[i + 1] *= adjust
                }
                i += 1
            }
            if adjusted { fit(points, slopes) }
        }

        /// FitRGBSpline.
        private mutating func fit(_ points: [(x: Double, y: Double)], _ slopes: [Double]) {
            knots = [points[0].x]
            a = []; b = []; c = []
            for i in 0..<(points.count - 1) {
                let (xi, yi) = points[i]
                let (x1, y1) = points[i + 1]
                let dx = x1 - xi
                let secant = (y1 - yi) / dx
                if abs((slopes[i] + slopes[i + 1]) - 2 * secant) < 1e-6 {
                    c.append(yi); b.append(slopes[i]); a.append(0.5 * (slopes[i + 1] - slopes[i]) / dx)
                } else {
                    let aa = slopes[i] - secant
                    let bb = slopes[i + 1] - secant
                    let ksi: Double
                    if aa * bb >= 0 {
                        ksi = (xi + x1) * 0.5
                    } else if abs(aa) > abs(bb) {
                        ksi = x1 + aa * dx / (slopes[i + 1] - slopes[i])
                    } else {
                        ksi = xi + bb * dx / (slopes[i + 1] - slopes[i])
                    }
                    let sBar = (2 * secant - slopes[i + 1]) + (slopes[i + 1] - slopes[i]) * (ksi - xi) / dx
                    let eta = (sBar - slopes[i]) / (ksi - xi)
                    c.append(yi); b.append(slopes[i]); a.append(0.5 * eta)
                    c.append(yi + slopes[i] * (ksi - xi) + 0.5 * eta * (ksi - xi) * (ksi - xi))
                    b.append(sBar)
                    a.append(0.5 * (slopes[i + 1] - sBar) / (x1 - ksi))
                    knots.append(ksi)
                }
                knots.append(x1)
            }
        }

        /// KnotsCoefs::evalCurve: linear beyond the ends, with the end segments' slopes.
        func eval(_ x: Double) -> Double {
            let first = knots[0], last = knots[knots.count - 1]
            if x <= first { return (x - first) * b[0] + c[0] }
            if x >= last {
                let n = a.count - 1
                let t = last - knots[knots.count - 2]
                return (x - last) * (2 * a[n] * t + b[n]) + (a[n] * t + b[n]) * t + c[n]
            }
            var i = 0
            while i < knots.count - 2 && !(x < knots[i + 1]) { i += 1 }
            let t = x - knots[i]
            return (a[i] * t + b[i]) * t + c[i]
        }
    }

    /// The RRT shaper in Generate_tonecurve_ops.
    static let rrtCurve = Curve(
        points: [(-5.26017743, -4), (-3.75502745, -3.57868829), (-2.24987747, -1.82131329),
                 (-0.74472749, 0.68124124), (1.06145248, 2.87457742), (2.86763245, 3.83406206),
                 (4.67381243, 4)],
        slopes: [0, 0.55982688, 1.77532247, 1.55, 0.8787017, 0.18374463, 0])

    /// The SDR ODT shaper in Generate_tonecurve_ops.
    static let odtCurve = Curve(
        points: [(-2.54062362, -1.69897000), (-2.08035721, -1.58843500), (-1.62009080, -1.35350000),
                 (-1.15982439, -1.04695000), (-0.69955799, -0.65640000), (-0.23929158, -0.22141000),
                 (0.22097483, 0.22814402), (0.68124124, 0.68124124), (1.01284632, 0.99142189),
                 (1.34445140, 1.25800000), (1.67605648, 1.44995000), (2.00766156, 1.55910000),
                 (2.33926665, 1.62260000), (2.67087173, 1.66065457), (3.00247681, 1.68124124)],
        slopes: [0, 0.4803088, 0.5405565, 0.79149813, 0.9055625, 0.98460368, 0.96884766, 1,
                 0.87078346, 0.73702127, 0.42068113, 0.23763206, 0.14535362, 0.08416378, 0.04])

    /// log10, both curves, back to linear, then the cinema white and black scale.
    static func toneCurve(_ v: Double) -> Double {
        let logV = log10(max(v, Double(Float.leastNormalMagnitude)))
        let y = pow(10, odtCurve.eval(rrtCurve.eval(logV)))
        let cinemaWhite = 48.0, cinemaBlack = 0.02
        return (y - cinemaBlack) / (cinemaWhite - cinemaBlack)
    }

    /// Renderer_ACES_DarkToDim10_Fwd with gamma 0.9811, on AP1.
    static func darkToDim(_ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        let y = max(1e-10, 0.27222871678091454 * rgb.0 + 0.67408176581114831 * rgb.1
                    + 0.053689517407937051 * rgb.2)
        let k = pow(y, 0.9811 - 1)
        return (rgb.0 * k, rgb.1 * k, rgb.2 * k)
    }

    // MARK: The view

    static func forward(_ aces: (Double, Double, Double)) -> (Double, Double, Double) {
        var v = redModifier(glow(aces))
        v = (max(v.0, 0), max(v.1, 0), max(v.2, 0))
        v = mult(ap0ToAP1, v)
        v = (max(v.0, 0), max(v.1, 0), max(v.2, 0))
        v = mult(rrtSatMatrix, v)
        v = (toneCurve(v.0), toneCurve(v.1), toneCurve(v.2))
        v = mult(desat100Nits, darkToDim(v))
        let rgb = mult(ap1ToRec709, v)
        // Rec.1886 with a 2.4 power, clamped to the display as a LUT needs.
        func encode(_ x: Double) -> Double { pow(min(max(x, 0), 1), 1 / 2.4) }
        return (encode(rgb.0), encode(rgb.1), encode(rgb.2))
    }
}
