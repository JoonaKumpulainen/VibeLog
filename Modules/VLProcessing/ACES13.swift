// Ported to Swift from the Academy's ACES 1.3 reference CTL, aces-dev tag v1.3.1: RRT.ctl,
// ODT.Academy.Rec709_100nits_dim.ctl and the ACESlib files they import.
//
//   Copyright © 2015 Academy of Motion Picture Arts and Sciences (A.M.P.A.S.).
//   Portions contributed by others as indicated. All rights reserved.
//
// Used under the License Terms for Academy Color Encoding System Components, with its conditions
// and Disclaimer of Warranty in LICENSES/ACES-1.3-AMPAS.txt. Changes from the original: translated
// to Swift, with only the forward RRT and the Rec.709 100-nit dim-surround ODT kept.

import Foundation

/// ACES 1.3: the Reference Rendering Transform, then the Rec.709 output transform for a 100 nit
/// display in a dim surround. ACES2065-1 in, Rec.1886 code values out.
enum ACES13Output {
    typealias M33 = [Double]

    // MARK: Matrices, in column-vector form, from ACESlib.Transform_Common and ODT_Common

    static let ap0ToXYZ = ACES2OutputTransform.rgbToXYZ(ACES2OutputTransform.ap0)
    static let ap1ToXYZ = ACES2OutputTransform.rgbToXYZ(ACES2OutputTransform.ap1)
    static let xyzToAP1 = ACES2OutputTransform.invert(ap1ToXYZ)
    static let ap0ToAP1 = ACES2OutputTransform.multiply(xyzToAP1, ap0ToXYZ)
    static let ap1ToAP0 = ACES2OutputTransform.invert(ap0ToAP1)
    static let xyzToRec709 = ACES2OutputTransform.invert(ACES2OutputTransform.rgbToXYZ(ACES2OutputTransform.rec709))
    static let ap1RGB2Y = [ap1ToXYZ[3], ap1ToXYZ[4], ap1ToXYZ[5]]

    /// calc_sat_adjust_matrix: each channel keeps `sat` of itself and takes the rest from luminance.
    static func saturationMatrix(_ sat: Double) -> M33 {
        var m = M33(repeating: 0, count: 9)
        for r in 0..<3 {
            for c in 0..<3 { m[r * 3 + c] = (1 - sat) * ap1RGB2Y[c] + (r == c ? sat : 0) }
        }
        return m
    }

    static let rrtSatMatrix = saturationMatrix(0.96)
    static let odtSatMatrix = saturationMatrix(0.93)

    /// calculate_cat_matrix with Bradford, from the ACES white to D65.
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

    @inline(__always) static func mult(_ m: M33, _ v: (Double, Double, Double)) -> (Double, Double, Double) {
        (m[0] * v.0 + m[1] * v.1 + m[2] * v.2,
         m[3] * v.0 + m[4] * v.1 + m[5] * v.2,
         m[6] * v.0 + m[7] * v.1 + m[8] * v.2)
    }

    // MARK: Constants

    static let glowGain = 0.05
    static let glowMid = 0.08
    static let redScale = 0.82
    static let redPivot = 0.03
    static let redHue = 0.0
    static let redWidth = 135.0
    static let cinemaWhite = 48.0
    static let cinemaBlack = 0.02
    static let dimSurroundGamma = 0.9811
    /// CTL's smallest positive half, the floor for the splines' log.
    static let halfMin = 5.96046448e-08
    static let halfMax = 65504.0

    // MARK: RRT sweeteners, from ACESlib.RRT_Common and Utilities_Color

    static func saturation(_ rgb: (Double, Double, Double)) -> Double {
        let hi = max(rgb.0, rgb.1, rgb.2)
        let lo = min(rgb.0, rgb.1, rgb.2)
        return (max(hi, 1e-10) - max(lo, 1e-10)) / max(hi, 1e-2)
    }

    static func yc(_ rgb: (Double, Double, Double)) -> Double {
        let (r, g, b) = rgb
        let chroma = (b * (b - g) + g * (g - r) + r * (r - b)).squareRoot()
        return (b + g + r + 1.75 * chroma) / 3
    }

    /// Undefined for a neutral, which the red modifier then leaves alone.
    static func hue(_ rgb: (Double, Double, Double)) -> Double? {
        if rgb.0 == rgb.1 && rgb.1 == rgb.2 { return nil }
        var h = (180 / Double.pi) * atan2(3.0.squareRoot() * (rgb.1 - rgb.2), 2 * rgb.0 - rgb.1 - rgb.2)
        if h < 0 { h += 360 }
        return h
    }

    static func sigmoidShaper(_ x: Double) -> Double {
        let t = max(1 - abs(x / 2), 0)
        let sign: Double = x > 0 ? 1 : x < 0 ? -1 : 0
        let y = 1 + sign * (1 - t * t)
        return y / 2
    }

    static func glowFwd(_ yc: Double, _ gain: Double, _ mid: Double) -> Double {
        if yc <= 2.0 / 3 * mid { return gain }
        if yc >= 2 * mid { return 0 }
        return gain * (mid / yc - 0.5)
    }

    static func cubicBasisShaper(_ x: Double, _ w: Double) -> Double {
        let M: [[Double]] = [
            [-1.0 / 6, 3.0 / 6, -3.0 / 6, 1.0 / 6],
            [3.0 / 6, -6.0 / 6, 3.0 / 6, 0],
            [-3.0 / 6, 0, 3.0 / 6, 0],
            [1.0 / 6, 4.0 / 6, 1.0 / 6, 0],
        ]
        let knots = [-w / 2, -w / 4, 0, w / 4, w / 2]
        var y = 0.0
        if x > knots[0] && x < knots[4] {
            let knotCoord = (x - knots[0]) * 4 / w
            let j = Int(knotCoord)
            let t = knotCoord - Double(j)
            let monomials = [t * t * t, t * t, t, 1]
            if (0...3).contains(j) {
                let column = 3 - j
                y = monomials[0] * M[0][column] + monomials[1] * M[1][column]
                    + monomials[2] * M[2][column] + monomials[3] * M[3][column]
            }
        }
        return y * 3 / 2
    }

    static func centerHue(_ hue: Double, _ center: Double) -> Double {
        var h = hue - center
        if h < -180 { h += 360 } else if h > 180 { h -= 360 }
        return h
    }

    // MARK: Tonescales, from ACESlib.Tonescales

    struct Spline {
        var coefsLow: [Double]
        var coefsHigh: [Double]
        var minPoint: (x: Double, y: Double)
        var midPoint: (x: Double, y: Double)
        var maxPoint: (x: Double, y: Double)
        var slopeLow: Double
        var slopeHigh: Double
        var knots: Int
    }

    static let rrtParams = Spline(
        coefsLow: [-4.0000000000, -4.0000000000, -3.1573765773, -0.4852499958, 1.8477324706, 1.8477324706],
        coefsHigh: [-0.7185482425, 2.0810307172, 3.6681241237, 4.0000000000, 4.0000000000, 4.0000000000],
        minPoint: (0.18 * pow(2, -15), 0.0001), midPoint: (0.18, 4.8), maxPoint: (0.18 * pow(2, 18), 10000),
        slopeLow: 0, slopeHigh: 0, knots: 4)

    static let odt48Nits = Spline(
        coefsLow: [-1.6989700043, -1.6989700043, -1.4779000000, -1.2291000000, -0.8648000000, -0.4480000000,
                   0.0051800000, 0.4511080334, 0.9113744414, 0.9113744414],
        coefsHigh: [0.5154386965, 0.8470437783, 1.1358000000, 1.3802000000, 1.5197000000, 1.5985000000,
                    1.6467000000, 1.6746091357, 1.6878733390, 1.6878733390],
        minPoint: (segmentedSpline(0.18 * pow(2, -6.5), rrtParams), 0.02),
        midPoint: (segmentedSpline(0.18, rrtParams), 4.8),
        maxPoint: (segmentedSpline(0.18 * pow(2, 6.5), rrtParams), 48),
        slopeLow: 0, slopeHigh: 0.04, knots: 8)

    /// segmented_spline_c5_fwd and c9_fwd, which differ only in their knot count.
    static func segmentedSpline(_ x: Double, _ C: Spline) -> Double {
        func basis(_ cf: [Double], _ t: Double) -> Double {
            // monomials {t², t, 1} times cf times M, with M from the CTL.
            let a = 0.5 * cf[0] - cf[1] + 0.5 * cf[2]
            let b = -cf[0] + cf[1]
            let c = 0.5 * cf[0] + 0.5 * cf[1]
            return t * t * a + t * b + c
        }
        let logx = log10(max(x, halfMin))
        let logMin = log10(C.minPoint.x)
        let logMid = log10(C.midPoint.x)
        let logMax = log10(C.maxPoint.x)
        let logy: Double
        if logx <= logMin {
            logy = logx * C.slopeLow + (log10(C.minPoint.y) - C.slopeLow * logMin)
        } else if logx < logMid {
            let knotCoord = Double(C.knots - 1) * (logx - logMin) / (logMid - logMin)
            let j = Int(knotCoord)
            logy = basis([C.coefsLow[j], C.coefsLow[j + 1], C.coefsLow[j + 2]], knotCoord - Double(j))
        } else if logx < logMax {
            let knotCoord = Double(C.knots - 1) * (logx - logMid) / (logMax - logMid)
            let j = Int(knotCoord)
            logy = basis([C.coefsHigh[j], C.coefsHigh[j + 1], C.coefsHigh[j + 2]], knotCoord - Double(j))
        } else {
            logy = logx * C.slopeHigh + (log10(C.maxPoint.y) - C.slopeHigh * logMax)
        }
        return pow(10, logy)
    }

    // MARK: The transforms

    /// RRT.ctl: ACES2065-1 to OCES.
    static func rrt(_ input: (Double, Double, Double)) -> (Double, Double, Double) {
        var aces = input
        let sat = saturation(aces)
        let s = sigmoidShaper((sat - 0.4) / 0.2)
        let addedGlow = 1 + glowFwd(yc(aces), glowGain * s, glowMid)
        aces = (aces.0 * addedGlow, aces.1 * addedGlow, aces.2 * addedGlow)
        if let h = hue(aces) {
            let weight = cubicBasisShaper(centerHue(h, redHue), redWidth)
            aces.0 = aces.0 + weight * sat * (redPivot - aces.0) * (1 - redScale)
        }
        aces = (max(aces.0, 0), max(aces.1, 0), max(aces.2, 0))
        var pre = mult(ap0ToAP1, aces)
        pre = (min(max(pre.0, 0), halfMax), min(max(pre.1, 0), halfMax), min(max(pre.2, 0), halfMax))
        pre = mult(rrtSatMatrix, pre)
        let post = (segmentedSpline(pre.0, rrtParams), segmentedSpline(pre.1, rrtParams), segmentedSpline(pre.2, rrtParams))
        return mult(ap1ToAP0, post)
    }

    static func darkToDimSurround(_ linearCV: (Double, Double, Double)) -> (Double, Double, Double) {
        let XYZ = mult(ap1ToXYZ, linearCV)
        var divisor = XYZ.0 + XYZ.1 + XYZ.2
        if divisor == 0 { divisor = 1e-10 }
        let x = XYZ.0 / divisor
        let y = XYZ.1 / divisor
        let Y = pow(max(XYZ.1, 0), dimSurroundGamma)
        let out = (x * Y / max(y, 1e-10), Y, (1 - x - y) * Y / max(y, 1e-10))
        return mult(xyzToAP1, out)
    }

    /// ODT.Academy.Rec709_100nits_dim.ctl: OCES to full-range Rec.1886 code values.
    static func odtRec709(_ oces: (Double, Double, Double)) -> (Double, Double, Double) {
        let pre = mult(ap0ToAP1, oces)
        let post = (segmentedSpline(pre.0, odt48Nits), segmentedSpline(pre.1, odt48Nits), segmentedSpline(pre.2, odt48Nits))
        func linCV(_ Y: Double) -> Double { (Y - cinemaBlack) / (cinemaWhite - cinemaBlack) }
        var cv = (linCV(post.0), linCV(post.1), linCV(post.2))
        cv = darkToDimSurround(cv)
        cv = mult(odtSatMatrix, cv)
        let XYZ = mult(d60ToD65, mult(ap1ToXYZ, cv))
        let rgb = mult(xyzToRec709, XYZ)
        // bt1886_r with L_W 1 and L_B 0 is a plain 1/2.4 power.
        func encode(_ v: Double) -> Double { pow(min(max(v, 0), 1), 1 / 2.4) }
        return (encode(rgb.0), encode(rgb.1), encode(rgb.2))
    }

    static func forward(_ aces: (Double, Double, Double)) -> (Double, Double, Double) {
        odtRec709(rrt(aces))
    }
}
