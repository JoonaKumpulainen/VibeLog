// Ported to Swift from OpenColorIO's ACES 2.0 output transform,
// src/OpenColorIO/ops/fixedfunction/ACES2 at commit 22dd9c4faa, which carries:
//
//   SPDX-License-Identifier: BSD-3-Clause
//   Copyright Contributors to the OpenColorIO Project.
//
// The full BSD 3-Clause terms are in LICENSES/OpenColorIO-BSD-3-Clause.txt. The algorithm is the
// Academy's ACES 2.0 Output Transform, under the Apache License 2.0 in LICENSES/ACES-Apache-2.0.txt.
// Changes from the original: translated to Swift, with only the forward SDR path kept. Names
// follow the original so the two can be compared line by line.

import Foundation

/// The ACES 2.0 Output Transform, forward only: ACES2065-1 in, display-linear RGB in the limiting
/// primaries out, where 1 is the peak luminance divided by 100 nits.
struct ACES2OutputTransform {
    typealias F3 = (Float, Float, Float)
    typealias M33 = [Float]

    // MARK: Constants, from Common.h

    static let hueLimit: Float = 360
    static let referenceLuminance: Float = 100
    static let L_A: Float = 100
    static let Y_b: Float = 20
    static let surround: F3 = (0.9, 0.59, 0.9)
    static let J_scale: Float = 100
    static let camNLYReference: Float = 100
    static let camNLOffset: Float = 0.2713 * camNLYReference
    static let camNLScale: Float = 4 * camNLYReference

    static let chromaCompress: Float = 2.4
    static let chromaCompressFact: Float = 3.3
    static let chromaExpand: Float = 1.3
    static let chromaExpandFact: Float = 0.69
    static let chromaExpandThr: Float = 0.5

    static let smoothCusps: Float = 0.12
    static let smoothM: Float = 0.27
    static let cuspMidBlend: Float = 1.3
    static let focusGainBlend: Float = 0.3
    static let focusDistance: Float = 1.35
    static let focusDistanceScaling: Float = 1.75
    static let compressionThreshold: Float = 0.75

    static let gammaMinimum: Float = 0
    static let gammaMaximum: Float = 5
    static let gammaSearchStep: Float = 0.4
    static let gammaAccuracy: Float = 1e-5

    static let cuspCornerCount = 6
    static let totalCornerCount = cuspCornerCount + 2
    static let maxSortedCorners = 2 * cuspCornerCount
    static let reachCuspTolerance: Float = 1e-3
    static let displayCuspTolerance: Float = 1e-7

    // Tables span 360 hues, with one entry below and two above for wrapping.
    static let baseIndex = 1
    static let nominalSize = 360
    static let totalSize = nominalSize + 3
    static let lowerWrapIndex = 0
    static let upperWrapIndex = baseIndex + nominalSize
    static let firstNominalIndex = baseIndex
    static let lastNominalIndex = upperWrapIndex - 1

    // MARK: Primaries and matrices

    struct Primaries {
        var red: (Double, Double)
        var green: (Double, Double)
        var blue: (Double, Double)
        var white: (Double, Double)
    }

    static let ap0 = Primaries(red: (0.7347, 0.2653), green: (0, 1), blue: (0.0001, -0.077), white: (0.32168, 0.33767))
    static let ap1 = Primaries(red: (0.713, 0.293), green: (0.165, 0.83), blue: (0.128, 0.044), white: (0.32168, 0.33767))
    static let rec709 = Primaries(red: (0.64, 0.33), green: (0.3, 0.6), blue: (0.15, 0.06), white: (0.3127, 0.329))
    static let p3d65 = Primaries(red: (0.68, 0.32), green: (0.265, 0.69), blue: (0.15, 0.06), white: (0.3127, 0.329))
    static let cam16 = Primaries(red: (0.8336, 0.1735), green: (2.3854, -1.4659), blue: (0.087, -0.125), white: (0.333, 0.333))

    /// RGB to XYZ, as rgb2xyz_from_xy, row-major.
    static func rgbToXYZ(_ p: Primaries) -> [Double] {
        let m: [Double] = [
            p.red.0, p.green.0, p.blue.0,
            p.red.1, p.green.1, p.blue.1,
            1 - p.red.0 - p.red.1, 1 - p.green.0 - p.green.1, 1 - p.blue.0 - p.blue.1,
        ]
        let inv = invert(m)
        let white = [p.white.0 / p.white.1, 1, (1 - p.white.0 - p.white.1) / p.white.1]
        var gains = [Double](repeating: 0, count: 3)
        for i in 0..<3 { gains[i] = white[0] * inv[i * 3] + white[1] * inv[i * 3 + 1] + white[2] * inv[i * 3 + 2] }
        var out = [Double](repeating: 0, count: 9)
        for j in 0..<3 {
            for i in 0..<3 { out[j * 3 + i] = gains[i] * m[j * 3 + i] }
        }
        return out
    }

    static func invert(_ m: [Double]) -> [Double] {
        let (a, b, c, d, e, f, g, h, i) = (m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8])
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        return [
            (e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
            (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
            (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det,
        ]
    }

    static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: 9)
        for r in 0..<3 {
            for c in 0..<3 { out[r * 3 + c] = a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c] }
        }
        return out
    }

    static func float(_ m: [Double]) -> M33 { m.map(Float.init) }

    static func multF33(_ a: M33, _ b: M33) -> M33 {
        float(multiply(a.map(Double.init), b.map(Double.init)))
    }

    static func invertF33(_ m: M33) -> M33 { float(invert(m.map(Double.init))) }

    static func diagonal(_ v: F3) -> M33 { [v.0, 0, 0, 0, v.1, 0, 0, 0, v.2] }

    @inline(__always) static func mult(_ v: F3, _ m: M33) -> F3 {
        (v.0 * m[0] + v.1 * m[1] + v.2 * m[2],
         v.0 * m[3] + v.1 * m[4] + v.2 * m[5],
         v.0 * m[6] + v.1 * m[7] + v.2 * m[8])
    }

    @inline(__always) static func lerpf(_ a: Float, _ b: Float, _ z: Float) -> Float { (b - a) * z + a }

    @inline(__always) static func wrapToHueLimit(_ hue: Float) -> Float {
        let y = fmodf(hue, hueLimit)
        return y < 0 ? y + hueLimit : y
    }

    @inline(__always) static func toRadians(_ v: Float) -> Float { Float.pi * v / 180 }

    /// The angle is already within (-180, 180], so it needs no fmod.
    @inline(__always) static func fromRadiansUnwrapped(_ v: Float) -> Float {
        let y = 180 * v / Float.pi
        return y < 0 ? y + hueLimit : y
    }

    // MARK: Parameters

    struct JMhParams {
        var rgbToCAM16c: M33
        var cam16cToRGB: M33
        var coneResponseToAab: M33
        var aabToConeResponse: M33
        var F_L_n: Float
        var cz: Float
        var inv_cz: Float
        var A_w_J: Float
        var inv_A_w_J: Float
    }

    struct ToneScaleParams {
        var n: Float
        var n_r: Float
        var g: Float
        var t_1: Float
        var c_t: Float
        var s_2: Float
        var u_2: Float
        var m_2: Float
        var forwardLimit: Float
        var inverseLimit: Float
        var logPeak: Float
    }

    struct SharedCompression {
        var limitJMax: Float
        var modelGammaInv: Float
        var reachMTable: [Float]
    }

    struct ResolvedCompression {
        var limitJMax: Float
        var modelGammaInv: Float
        var reachMaxM: Float
    }

    struct ChromaCompressParams {
        var sat: Float
        var satThr: Float
        var compr: Float
        var chromaCompressScale: Float
    }

    struct HueDependantGamutParams {
        var gammaBottomInv: Float
        var JMcusp: (Float, Float)
        var gammaTopInv: Float
        var focusJ: Float
        var analyticalThreshold: Float
    }

    struct GamutCompressParams {
        var midJ: Float
        var focusDist: Float
        var lowerHullGammaInv: Float
        var hueSearchRange: (Int, Int)
        var hueTable: [Float]
        var cuspTable: [F3]
    }

    let pIn: JMhParams
    let pOut: JMhParams
    let tone: ToneScaleParams
    let shared: SharedCompression
    let chroma: ChromaCompressParams
    let gamut: GamutCompressParams

    /// As Renderer_ACES_OutputTransform20, for a peak in nits and the limiting primaries.
    init(peakLuminance: Float = 100, limiting: Primaries = rec709) {
        let input = Self.initJMhParams(Self.ap0)
        let output = Self.initJMhParams(limiting)
        let toneScale = Self.initToneScaleParams(peakLuminance)
        let reach = Self.initJMhParams(Self.ap1)
        let sharedParams = Self.initSharedCompression(peakLuminance, input, reach)
        pIn = input
        pOut = output
        tone = toneScale
        shared = sharedParams
        chroma = Self.initChromaCompress(peakLuminance, toneScale)
        gamut = Self.initGamutCompress(peakLuminance, input, output, toneScale, sharedParams, reach)
    }

    // MARK: CAM

    @inline(__always) static func coneCompressFwd(_ Rc: Float) -> Float {
        let F_L_Y = powf(Rc, 0.42)
        return F_L_Y / (camNLOffset + F_L_Y)
    }

    @inline(__always) static func coneCompressInv(_ Ra: Float) -> Float {
        let Ra_lim = min(Ra, 0.99)
        let F_L_Y = (camNLOffset * Ra_lim) / (1 - Ra_lim)
        return powf(F_L_Y, 1 / 0.42)
    }

    @inline(__always) static func postAdaptationConeResponseCompressionFwd(_ v: Float) -> Float {
        copysignf(coneCompressFwd(abs(v)), v)
    }

    @inline(__always) static func postAdaptationConeResponseCompressionInv(_ v: Float) -> Float {
        copysignf(coneCompressInv(abs(v)), v)
    }

    @inline(__always) static func achromaticToJ(_ A: Float, _ cz: Float) -> Float { J_scale * powf(A, cz) }

    @inline(__always) static func jToAchromatic(_ J: Float, _ inv_cz: Float) -> Float { powf(J * (1 / J_scale), inv_cz) }

    @inline(__always) static func aToY(_ A: Float, _ p: JMhParams) -> Float {
        coneCompressInv(p.A_w_J * A) / p.F_L_n
    }

    @inline(__always) static func yToJUnsigned(_ absY: Float, _ p: JMhParams) -> Float {
        let Ra = coneCompressFwd(absY * p.F_L_n)
        return achromaticToJ(Ra * p.inv_A_w_J, p.cz)
    }

    static func yToJ(_ Y: Float, _ p: JMhParams) -> Float {
        copysignf(yToJUnsigned(abs(Y), p), Y)
    }

    @inline(__always) static func rgbToAab(_ rgb: F3, _ p: JMhParams) -> F3 {
        let m = mult(rgb, p.rgbToCAM16c)
        let a = (postAdaptationConeResponseCompressionFwd(m.0),
                 postAdaptationConeResponseCompressionFwd(m.1),
                 postAdaptationConeResponseCompressionFwd(m.2))
        return mult(a, p.coneResponseToAab)
    }

    @inline(__always) static func aabToJMh(_ Aab: F3, _ p: JMhParams) -> F3 {
        if Aab.0 <= 0 { return (0, 0, 0) }
        let J = achromaticToJ(Aab.0, p.cz)
        let M = (Aab.1 * Aab.1 + Aab.2 * Aab.2).squareRoot()
        let h = fromRadiansUnwrapped(atan2f(Aab.2, Aab.1))
        return (J, M, h)
    }

    static func rgbToJMh(_ rgb: F3, _ p: JMhParams) -> F3 { aabToJMh(rgbToAab(rgb, p), p) }

    @inline(__always) static func jmhToAab(_ JMh: F3, _ cosH: Float, _ sinH: Float, _ p: JMhParams) -> F3 {
        (jToAchromatic(JMh.0, p.inv_cz), JMh.1 * cosH, JMh.1 * sinH)
    }

    static func jmhToAab(_ JMh: F3, _ p: JMhParams) -> F3 {
        let h = toRadians(JMh.2)
        return jmhToAab(JMh, cosf(h), sinf(h), p)
    }

    @inline(__always) static func aabToRGB(_ Aab: F3, _ p: JMhParams) -> F3 {
        let a = mult(Aab, p.aabToConeResponse)
        let m = (postAdaptationConeResponseCompressionInv(a.0),
                 postAdaptationConeResponseCompressionInv(a.1),
                 postAdaptationConeResponseCompressionInv(a.2))
        return mult(m, p.cam16cToRGB)
    }

    static func jmhToRGB(_ JMh: F3, _ p: JMhParams) -> F3 { aabToRGB(jmhToAab(JMh, p), p) }

    static func modelGamma() -> Float { surround.1 * (1.48 + (Y_b / referenceLuminance).squareRoot()) }

    static func initJMhParams(_ prims: Primaries) -> JMhParams {
        let baseConeResponseToAab: M33 = [
            2, 1, 1.0 / 20,
            1, -12.0 / 11, 1.0 / 11,
            1.0 / 9, 1.0 / 9, -2.0 / 9,
        ]
        let matrix16 = float(invert(rgbToXYZ(cam16)))
        let rgbToXYZm = float(rgbToXYZ(prims))
        let XYZ_w = mult((referenceLuminance, referenceLuminance, referenceLuminance), rgbToXYZm)
        let Y_W = XYZ_w.1
        let RGB_w = mult(XYZ_w, matrix16)

        let K: Float = 1 / (5 * L_A + 1)
        let K4 = K * K * K * K
        let F_L = 0.2 * K4 * (5 * L_A) + 0.1 * powf(1 - K4, 2) * powf(5 * L_A, 1.0 / 3)
        let F_L_n = F_L / referenceLuminance
        let cz = modelGamma()
        let D_RGB = (F_L_n * Y_W / RGB_w.0, F_L_n * Y_W / RGB_w.1, F_L_n * Y_W / RGB_w.2)
        let RGB_WC = (D_RGB.0 * RGB_w.0, D_RGB.1 * RGB_w.1, D_RGB.2 * RGB_w.2)
        let RGB_AW = (postAdaptationConeResponseCompressionFwd(RGB_WC.0),
                      postAdaptationConeResponseCompressionFwd(RGB_WC.1),
                      postAdaptationConeResponseCompressionFwd(RGB_WC.2))

        let coneResponseToAab = multF33(diagonal((camNLScale, camNLScale, camNLScale)), baseConeResponseToAab)
        let A_w = coneResponseToAab[0] * RGB_AW.0 + coneResponseToAab[1] * RGB_AW.1 + coneResponseToAab[2] * RGB_AW.2
        let A_w_J = coneCompressFwd(F_L)

        let rgbToCAM16 = multF33(
            float(multiply(invert(rgbToXYZ(cam16)), rgbToXYZ(prims))),
            diagonal((referenceLuminance, referenceLuminance, referenceLuminance)))
        let rgbToCAM16c = multF33(diagonal(D_RGB), rgbToCAM16)
        let s = 43 * surround.2
        let toAab: M33 = [
            coneResponseToAab[0] / A_w, coneResponseToAab[1] / A_w, coneResponseToAab[2] / A_w,
            coneResponseToAab[3] * s, coneResponseToAab[4] * s, coneResponseToAab[5] * s,
            coneResponseToAab[6] * s, coneResponseToAab[7] * s, coneResponseToAab[8] * s,
        ]
        return JMhParams(
            rgbToCAM16c: rgbToCAM16c, cam16cToRGB: invertF33(rgbToCAM16c),
            coneResponseToAab: toAab, aabToConeResponse: invertF33(toAab),
            F_L_n: F_L_n, cz: cz, inv_cz: 1 / cz, A_w_J: A_w_J, inv_A_w_J: 1 / A_w_J)
    }

    // MARK: Tonescale and chroma compression

    static func chromaCompressNorm(_ cosH1: Float, _ sinH1: Float, _ scale: Float) -> Float {
        let cosH2 = 2 * cosH1 * cosH1 - 1
        let sinH2 = 2 * cosH1 * sinH1
        let cosH3 = 4 * cosH1 * cosH1 * cosH1 - 3 * cosH1
        let sinH3 = 3 * sinH1 - 4 * sinH1 * sinH1 * sinH1
        let cosines: Float = 11.34072 * cosH1 + 16.46899 * cosH2 + 7.88380 * cosH3
        let sines: Float = 14.66441 * sinH1 - 6.37224 * sinH2 + 9.19364 * sinH3
        return (cosines + sines + 77.12896) * scale
    }

    @inline(__always) static func toeFwd(_ x: Float, _ limit: Float, _ k1In: Float, _ k2In: Float) -> Float {
        if x > limit { return x }
        let k2 = max(k2In, 0.001)
        let k1 = (k1In * k1In + k2 * k2).squareRoot()
        let k3 = (limit + k1) / (limit + k2)
        let minusB = k3 * x - k1
        let minusAC = k2 * k3 * x
        return 0.5 * (minusB + (minusB * minusB + 4 * minusAC).squareRoot())
    }

    @inline(__always) static func acesTonescaleFwd(_ Y: Float, _ pt: ToneScaleParams) -> Float {
        let f = pt.m_2 * powf(Y / (Y + pt.s_2), pt.g)
        return max(0, f * f / (f + pt.t_1)) * pt.n_r
    }

    @inline(__always) static func tonescaleAToJFwd(_ A: Float, _ p: JMhParams, _ pt: ToneScaleParams) -> Float {
        let Yout = acesTonescaleFwd(aToY(A, p), pt)
        return copysignf(yToJUnsigned(Yout, p), A)
    }

    static func chromaCompressFwd(
        _ JMh: F3, _ J_ts: Float, _ Mnorm: Float, _ pr: ResolvedCompression, _ pc: ChromaCompressParams
    ) -> F3 {
        let (J, M, h) = JMh
        var Mcp = M
        if M != 0 {
            let nJ = J_ts / pr.limitJMax
            let snJ = max(0, 1 - nJ)
            let limit = powf(nJ, pr.modelGammaInv) * pr.reachMaxM / Mnorm
            Mcp = M * powf(J_ts / J, pr.modelGammaInv)
            Mcp = Mcp / Mnorm
            Mcp = limit - toeFwd(limit - Mcp, limit - 0.001, snJ * pc.sat, (nJ * nJ + pc.satThr).squareRoot())
            Mcp = toeFwd(Mcp, limit, nJ * pc.compr, snJ)
            Mcp = Mcp * Mnorm
        }
        return (J_ts, Mcp, h)
    }

    static func initToneScaleParams(_ peakLuminance: Float) -> ToneScaleParams {
        let n = peakLuminance
        let n_r: Float = 100
        let g: Float = 1.15
        let c: Float = 0.18
        let c_d: Float = 10.013
        let w_g: Float = 0.14
        let t_1: Float = 0.04
        let r_hit_min: Float = 128
        let r_hit_max: Float = 896
        let r_hit = r_hit_min + (r_hit_max - r_hit_min) * (logf(n / n_r) / logf(10000 / 100))
        let m_0 = n / n_r
        let m_1 = 0.5 * (m_0 + (m_0 * (m_0 + 4 * t_1)).squareRoot())
        let u = powf((r_hit / m_1) / ((r_hit / m_1) + 1), g)
        let m = m_1 / u
        let w_i = logf(n / 100) / logf(2)
        let c_t = c_d / n_r * (1 + w_i * w_g)
        let g_ip = 0.5 * (c_t + (c_t * (c_t + 4 * t_1)).squareRoot())
        let g_ipp2 = -(m_1 * powf(g_ip / m, 1 / g)) / (powf(g_ip / m, 1 / g) - 1)
        let w_2 = c / g_ipp2
        let s_2 = w_2 * m_1 * referenceLuminance
        let u_2 = powf((r_hit / m_1) / ((r_hit / m_1) + w_2), g)
        let m_2 = m_1 / u_2
        return ToneScaleParams(
            n: n, n_r: n_r, g: g, t_1: t_1, c_t: c_t, s_2: s_2, u_2: u_2, m_2: m_2,
            forwardLimit: 8 * r_hit, inverseLimit: n / (u_2 * n_r), logPeak: log10f(n / n_r))
    }

    static func initChromaCompress(_ peakLuminance: Float, _ ts: ToneScaleParams) -> ChromaCompressParams {
        ChromaCompressParams(
            sat: max(0.2, chromaExpand - (chromaExpand * chromaExpandFact) * ts.logPeak),
            satThr: chromaExpandThr / ts.n,
            compr: chromaCompress + (chromaCompress * chromaCompressFact) * ts.logPeak,
            chromaCompressScale: powf(0.03379 * peakLuminance, 0.30596) - 0.45135)
    }

    // MARK: Shared compression and the reach table

    static func anyBelowZero(_ rgb: F3) -> Bool { rgb.0 < 0 || rgb.1 < 0 || rgb.2 < 0 }

    static func makeReachMTable(_ params: JMhParams, _ limitJMax: Float) -> [Float] {
        var table = [Float](repeating: 0, count: totalSize)
        for i in 0..<nominalSize {
            let hue = Float(i)
            let searchRange: Float = 50
            let searchMaximum: Float = 1300
            var low: Float = 0
            var high = low + searchRange
            var outside = false
            while !outside && high < searchMaximum {
                outside = anyBelowZero(jmhToRGB((limitJMax, high, hue), params))
                if !outside {
                    low = high
                    high = high + searchRange
                }
            }
            while high - low > 1e-2 {
                let sampleM = (high + low) / 2
                outside = anyBelowZero(jmhToRGB((limitJMax, sampleM, hue), params))
                if outside { high = sampleM } else { low = sampleM }
            }
            table[i + baseIndex] = high
        }
        table[lowerWrapIndex] = table[lastNominalIndex]
        table[upperWrapIndex] = table[firstNominalIndex]
        table[upperWrapIndex + 1] = table[firstNominalIndex + 1]
        return table
    }

    static func initSharedCompression(_ peak: Float, _ input: JMhParams, _ reach: JMhParams) -> SharedCompression {
        let limitJMax = yToJ(peak, input)
        return SharedCompression(
            limitJMax: limitJMax, modelGammaInv: 1 / modelGamma(), reachMTable: makeReachMTable(reach, limitJMax))
    }

    @inline(__always) static func reachMFromTable(_ h: Float, _ table: [Float]) -> Float {
        let base = Int(h)
        let t = h - Float(base)
        let iLo = base + firstNominalIndex
        return lerpf(table[iLo], table[iLo + 1], t)
    }

    @inline(__always) func resolve(_ hue: Float) -> ResolvedCompression {
        ResolvedCompression(
            limitJMax: shared.limitJMax, modelGammaInv: shared.modelGammaInv,
            reachMaxM: Self.reachMFromTable(hue, shared.reachMTable))
    }

    // MARK: Gamut cusp tables

    static func unitCubeCuspCorner(_ corner: Int) -> F3 {
        // Generation order R, Y, G, C, B, M, so hues rotate in the right order.
        (((corner + 1) % cuspCornerCount) < 3 ? 1 : 0,
         ((corner + 5) % cuspCornerCount) < 3 ? 1 : 0,
         ((corner + 3) % cuspCornerCount) < 3 ? 1 : 0)
    }

    static func buildLimitingCuspCorners(_ params: JMhParams, _ peak: Float) -> (rgb: [F3], jmh: [F3]) {
        var tempRGB = [F3](repeating: (0, 0, 0), count: cuspCornerCount)
        var tempJMh = [F3](repeating: (0, 0, 0), count: cuspCornerCount)
        var minIndex = 0
        for i in 0..<cuspCornerCount {
            let c = unitCubeCuspCorner(i)
            let scale = peak / referenceLuminance
            tempRGB[i] = (scale * c.0, scale * c.1, scale * c.2)
            tempJMh[i] = rgbToJMh(tempRGB[i], params)
            if tempJMh[i].2 < tempJMh[minIndex].2 { minIndex = i }
        }
        var rgb = [F3](repeating: (0, 0, 0), count: totalCornerCount)
        var jmh = [F3](repeating: (0, 0, 0), count: totalCornerCount)
        for i in 0..<cuspCornerCount {
            rgb[i + 1] = tempRGB[(i + minIndex) % cuspCornerCount]
            jmh[i + 1] = tempJMh[(i + minIndex) % cuspCornerCount]
        }
        rgb[0] = rgb[cuspCornerCount]
        rgb[cuspCornerCount + 1] = rgb[1]
        jmh[0] = jmh[cuspCornerCount]
        jmh[cuspCornerCount + 1] = jmh[1]
        jmh[0].2 -= hueLimit
        jmh[cuspCornerCount + 1].2 += hueLimit
        return (rgb, jmh)
    }

    static func findReachCorners(_ params: JMhParams, _ limitJ: Float, _ maximumSource: Float) -> [F3] {
        var temp = [F3](repeating: (0, 0, 0), count: cuspCornerCount)
        let limitA = jToAchromatic(limitJ, params.inv_cz)
        var minIndex = 0
        for i in 0..<cuspCornerCount {
            let v = unitCubeCuspCorner(i)
            var lower: Float = 0
            var upper = maximumSource
            while upper - lower > reachCuspTolerance {
                let test = (lower + upper) / 2
                let A = rgbToAab((test * v.0, test * v.1, test * v.2), params).0
                if A < limitA { lower = test } else { upper = test }
                if A == limitA { break }
            }
            temp[i] = rgbToJMh((upper * v.0, upper * v.1, upper * v.2), params)
            if temp[i].2 < temp[minIndex].2 { minIndex = i }
        }
        var jmh = [F3](repeating: (0, 0, 0), count: totalCornerCount)
        for i in 0..<cuspCornerCount { jmh[i + 1] = temp[(i + minIndex) % cuspCornerCount] }
        jmh[0] = jmh[cuspCornerCount]
        jmh[cuspCornerCount + 1] = jmh[1]
        jmh[0].2 -= hueLimit
        jmh[cuspCornerCount + 1].2 += hueLimit
        return jmh
    }

    static func extractSortedCubeHues(_ reach: [F3], _ display: [F3]) -> [Float] {
        var sorted: [Float] = []
        var reachIndex = 1
        var displayIndex = 1
        while reachIndex < cuspCornerCount + 1 || displayIndex < cuspCornerCount + 1 {
            let reachHue = reach[reachIndex].2
            let displayHue = display[displayIndex].2
            if reachHue == displayHue {
                sorted.append(reachHue)
                reachIndex += 1
                displayIndex += 1
            } else if reachHue < displayHue {
                sorted.append(reachHue)
                reachIndex += 1
            } else {
                sorted.append(displayHue)
                displayIndex += 1
            }
        }
        return sorted
    }

    static func buildHueSampleInterval(_ samples: Int, _ lower: Float, _ upper: Float, _ table: inout [Float], _ base: Int) {
        let delta = (upper - lower) / Float(samples)
        for i in 0..<max(samples, 0) { table[base + i] = lower + Float(i) * delta }
    }

    static func buildHueTable(_ sortedHues: [Float]) -> [Float] {
        var table = [Float](repeating: 0, count: totalSize)
        let uniqueHues = sortedHues.count
        let idealSpacing = Float(nominalSize) / hueLimit
        var samplesCount = [Int](repeating: 0, count: 2 * cuspCornerCount + 2)
        var lastIndex = Int.max
        var minIndex = sortedHues[0] == 0 ? 0 : 1
        for hueIndex in 0..<uniqueHues {
            var nominalIndex = min(max(Int((sortedHues[hueIndex] * idealSpacing).rounded()), minIndex), nominalSize - 1)
            if lastIndex == nominalIndex {
                if hueIndex > 1 && samplesCount[hueIndex - 2] != samplesCount[hueIndex - 1] - 1 {
                    samplesCount[hueIndex - 1] -= 1
                } else {
                    nominalIndex += 1
                }
            }
            samplesCount[hueIndex] = min(nominalIndex, nominalSize - 1)
            lastIndex = nominalIndex
            minIndex = nominalIndex
        }
        var totalSamples = 0
        var i = 0
        buildHueSampleInterval(samplesCount[i], 0, sortedHues[i], &table, totalSamples + 1)
        totalSamples += samplesCount[i]
        i += 1
        while i != uniqueHues {
            let samples = samplesCount[i] - samplesCount[i - 1]
            buildHueSampleInterval(samples, sortedHues[i - 1], sortedHues[i], &table, totalSamples + 1)
            totalSamples += samples
            i += 1
        }
        buildHueSampleInterval(nominalSize - totalSamples, sortedHues[i - 1], hueLimit, &table, totalSamples + 1)
        table[lowerWrapIndex] = table[lastNominalIndex] - hueLimit
        table[upperWrapIndex] = table[firstNominalIndex] + hueLimit
        table[upperWrapIndex + 1] = table[firstNominalIndex + 1] + hueLimit
        return table
    }

    static func findDisplayCuspForHue(
        _ hue: Float, _ rgbCorners: [F3], _ jmhCorners: [F3], _ params: JMhParams, _ previous: inout (Float, Float)
    ) -> (Float, Float) {
        var upperCorner = 1
        for i in 1..<totalCornerCount where jmhCorners[i].2 > hue {
            upperCorner = i
            break
        }
        let lowerCorner = upperCorner - 1
        if jmhCorners[lowerCorner].2 == hue {
            return (jmhCorners[lowerCorner].0, jmhCorners[lowerCorner].1)
        }
        let lo = rgbCorners[lowerCorner]
        let hi = rgbCorners[upperCorner]
        func lerp3(_ t: Float) -> F3 { (lerpf(lo.0, hi.0, t), lerpf(lo.1, hi.1, t), lerpf(lo.2, hi.2, t)) }
        var lowerT: Float = Float(upperCorner) == previous.0 ? previous.1 : 0
        var upperT: Float = 1
        while upperT - lowerT > displayCuspTolerance {
            let sampleT = (lowerT + upperT) / 2
            let JMh = rgbToJMh(lerp3(sampleT), params)
            if JMh.2 < jmhCorners[lowerCorner].2 {
                upperT = sampleT
            } else if JMh.2 >= jmhCorners[upperCorner].2 {
                lowerT = sampleT
            } else if JMh.2 > hue {
                upperT = sampleT
            } else {
                lowerT = sampleT
            }
        }
        let sampleT = (lowerT + upperT) / 2
        let JMh = rgbToJMh(lerp3(sampleT), params)
        previous = (Float(upperCorner), sampleT)
        return (JMh.0, JMh.1)
    }

    static func buildCuspTable(_ hueTable: [Float], _ rgbCorners: [F3], _ jmhCorners: [F3], _ params: JMhParams) -> [F3] {
        var previous: (Float, Float) = (0, 0)
        var table = [F3](repeating: (0, 0, 0), count: totalSize)
        for i in firstNominalIndex..<upperWrapIndex {
            let hue = hueTable[i]
            let JM = findDisplayCuspForHue(hue, rgbCorners, jmhCorners, params, &previous)
            table[i] = (JM.0, JM.1 * (1 + smoothM * smoothCusps), hue)
        }
        table[lowerWrapIndex] = (table[lastNominalIndex].0, table[lastNominalIndex].1, hueTable[lowerWrapIndex])
        table[upperWrapIndex] = (table[firstNominalIndex].0, table[firstNominalIndex].1, hueTable[upperWrapIndex])
        table[upperWrapIndex + 1] = (
            table[firstNominalIndex + 1].0, table[firstNominalIndex + 1].1, hueTable[upperWrapIndex + 1])
        return table
    }

    // MARK: Gamut compression

    @inline(__always) static func getFocusGain(_ J: Float, _ threshold: Float, _ limitJMax: Float, _ focusDist: Float) -> Float {
        var gain = limitJMax * focusDist
        if J > threshold {
            var adjustment = log10f((limitJMax - threshold) / max(0.0001, limitJMax - J))
            adjustment = adjustment * adjustment + 1
            gain = gain * adjustment
        }
        return gain
    }

    @inline(__always) static func solveJIntersect(_ J: Float, _ M: Float, _ focusJ: Float, _ maxJ: Float, _ slopeGain: Float) -> Float {
        let Mscaled = M / slopeGain
        let a = Mscaled / focusJ
        if J < focusJ {
            let b = 1 - Mscaled
            let c = -J
            let root = (b * b - 4 * a * c).squareRoot()
            return -2 * c / (b + root)
        } else {
            let b = -(1 + Mscaled + maxJ * a)
            let c = maxJ * Mscaled + J
            let root = (b * b - 4 * a * c).squareRoot()
            return -2 * c / (b - root)
        }
    }

    @inline(__always) static func sminScaled(_ a: Float, _ b: Float, _ reference: Float) -> Float {
        let s = smoothCusps * reference
        let h = max(s - abs(a - b), 0) / s
        return min(a, b) - h * h * h * s * (1.0 / 6)
    }

    @inline(__always) static func compressionVectorSlope(_ intersectJ: Float, _ focusJ: Float, _ limitJMax: Float, _ slopeGain: Float) -> Float {
        let directionScaler = intersectJ < focusJ ? intersectJ : limitJMax - intersectJ
        return directionScaler * (intersectJ - focusJ) / (focusJ * slopeGain)
    }

    @inline(__always) static func lineBoundaryIntersectionM(
        _ jAxisIntersect: Float, _ slope: Float, _ invGamma: Float, _ jMax: Float, _ mMax: Float, _ jReference: Float
    ) -> Float {
        let normalisedJ = jAxisIntersect / jReference
        let shifted = jReference * powf(normalisedJ, invGamma)
        return shifted * mMax / (jMax - slope * mMax)
    }

    static func findGamutBoundaryIntersection(
        _ JMcusp: (Float, Float), _ jMax: Float, _ gammaTopInv: Float, _ gammaBottomInv: Float,
        _ jIntersectSource: Float, _ slope: Float, _ jIntersectCusp: Float
    ) -> Float {
        let lower = lineBoundaryIntersectionM(jIntersectSource, slope, gammaBottomInv, JMcusp.0, JMcusp.1, jIntersectCusp)
        let upper = lineBoundaryIntersectionM(
            jMax - jIntersectSource, -slope, gammaTopInv, jMax - JMcusp.0, JMcusp.1, jMax - jIntersectCusp)
        return sminScaled(lower, upper, JMcusp.1)
    }

    @inline(__always) static func remapM(_ M: Float, _ gamutBoundaryM: Float, _ reachBoundaryM: Float) -> Float {
        let proportion = max(gamutBoundaryM / reachBoundaryM, compressionThreshold)
        let threshold = proportion * gamutBoundaryM
        if M <= threshold || proportion >= 1 { return M }
        let mOffset = M - threshold
        let gamutOffset = gamutBoundaryM - threshold
        let reachOffset = reachBoundaryM - threshold
        let scale = reachOffset / ((reachOffset / gamutOffset) - 1)
        let nd = mOffset / scale
        return threshold + scale * nd / (1 + nd)
    }

    static func computeFocusJ(_ cuspJ: Float, _ midJ: Float, _ limitJMax: Float) -> Float {
        lerpf(cuspJ, midJ, min(1, cuspMidBlend - (cuspJ / limitJMax)))
    }

    static func lookupHueInterval(_ h: Float, _ hues: [Float], _ range: (Int, Int)) -> Int {
        var i = firstNominalIndex + Int(h)
        var lo = max(lowerWrapIndex, i + range.0)
        var hi = min(upperWrapIndex, i + range.1)
        while lo + 1 < hi {
            if h > hues[i] { lo = i } else { hi = i }
            i = (lo + hi) / 2
        }
        return max(1, hi)
    }

    func hueDependantParams(_ hue: Float, _ sr: ResolvedCompression) -> HueDependantGamutParams {
        let p = gamut
        let iHi = Self.lookupHueInterval(hue, p.hueTable, p.hueSearchRange)
        let t = (hue - p.hueTable[iHi - 1]) / (p.hueTable[iHi] - p.hueTable[iHi - 1])
        let lo = p.cuspTable[iHi - 1]
        let hi = p.cuspTable[iHi]
        let cusp = (Self.lerpf(lo.0, hi.0, t), Self.lerpf(lo.1, hi.1, t), Self.lerpf(lo.2, hi.2, t))
        return HueDependantGamutParams(
            gammaBottomInv: p.lowerHullGammaInv, JMcusp: (cusp.0, cusp.1), gammaTopInv: cusp.2,
            focusJ: Self.computeFocusJ(cusp.0, p.midJ, sr.limitJMax),
            analyticalThreshold: Self.lerpf(cusp.0, sr.limitJMax, Self.focusGainBlend))
    }

    func compressGamut(_ JMh: F3, _ Jx: Float, _ sr: ResolvedCompression, _ hdp: HueDependantGamutParams) -> F3 {
        let (J, M, h) = JMh
        let slopeGain = Self.getFocusGain(Jx, hdp.analyticalThreshold, sr.limitJMax, gamut.focusDist)
        let jIntersectSource = Self.solveJIntersect(J, M, hdp.focusJ, sr.limitJMax, slopeGain)
        let slope = Self.compressionVectorSlope(jIntersectSource, hdp.focusJ, sr.limitJMax, slopeGain)
        let jIntersectCusp = Self.solveJIntersect(hdp.JMcusp.0, hdp.JMcusp.1, hdp.focusJ, sr.limitJMax, slopeGain)
        let boundaryM = Self.findGamutBoundaryIntersection(
            hdp.JMcusp, sr.limitJMax, hdp.gammaTopInv, hdp.gammaBottomInv, jIntersectSource, slope, jIntersectCusp)
        if boundaryM <= 0 { return (J, 0, h) }
        let reachBoundaryM = Self.lineBoundaryIntersectionM(
            jIntersectSource, slope, sr.modelGammaInv, sr.limitJMax, sr.reachMaxM, sr.limitJMax)
        let remapped = Self.remapM(M, boundaryM, reachBoundaryM)
        return (jIntersectSource + remapped * slope, remapped, h)
    }

    func gamutCompressFwd(_ JMh: F3, _ sr: ResolvedCompression) -> F3 {
        let (J, M, h) = JMh
        if J <= 0 { return (0, 0, h) }
        if M <= 0 || J > sr.limitJMax { return (J, 0, h) }
        return compressGamut(JMh, J, sr, hueDependantParams(h, sr))
    }

    // MARK: Upper hull gamma

    struct GammaTest {
        var testJMh: F3
        var jIntersectSource: Float
        var slope: Float
        var jIntersectCusp: Float
    }

    static func gammaTestData(_ JMcusp: (Float, Float), _ hue: Float, _ limitJMax: Float, _ midJ: Float, _ focusDist: Float) -> [GammaTest] {
        let positions: [Float] = [0.01, 0.1, 0.5, 0.8, 0.99]
        let threshold = lerpf(JMcusp.0, limitJMax, focusGainBlend)
        let focusJ = computeFocusJ(JMcusp.0, midJ, limitJMax)
        return positions.map { position in
            let testJ = lerpf(JMcusp.0, limitJMax, position)
            let slopeGain = getFocusGain(testJ, threshold, limitJMax, focusDist)
            let source = solveJIntersect(testJ, JMcusp.1, focusJ, limitJMax, slopeGain)
            return GammaTest(
                testJMh: (testJ, JMcusp.1, hue), jIntersectSource: source,
                slope: compressionVectorSlope(source, focusJ, limitJMax, slopeGain),
                jIntersectCusp: solveJIntersect(JMcusp.0, JMcusp.1, focusJ, limitJMax, slopeGain))
        }
    }

    static func evaluateGammaFit(
        _ JMcusp: (Float, Float), _ data: [GammaTest], _ topGammaInv: Float, _ peak: Float, _ limitJMax: Float,
        _ lowerHullGammaInv: Float, _ limitParams: JMhParams
    ) -> Bool {
        let luminanceLimit = peak / referenceLuminance
        for test in data {
            let approxM = findGamutBoundaryIntersection(
                JMcusp, limitJMax, topGammaInv, lowerHullGammaInv, test.jIntersectSource, test.slope, test.jIntersectCusp)
            let approxJ = test.jIntersectSource + test.slope * approxM
            let rgb = jmhToRGB((approxJ, approxM, test.testJMh.2), limitParams)
            if !(rgb.0 > luminanceLimit || rgb.1 > luminanceLimit || rgb.2 > luminanceLimit) { return false }
        }
        return true
    }

    static func makeUpperHullGamma(
        _ hueTable: [Float], _ table: inout [F3], _ peak: Float, _ limitJMax: Float, _ midJ: Float, _ focusDist: Float,
        _ lowerHullGammaInv: Float, _ limitParams: JMhParams
    ) {
        for i in firstNominalIndex..<upperWrapIndex {
            let hue = hueTable[i]
            let JMcusp = (table[i].0, table[i].1)
            let data = gammaTestData(JMcusp, hue, limitJMax, midJ, focusDist)
            func fits(_ gamma: Float) -> Bool {
                evaluateGammaFit(JMcusp, data, 1 / gamma, peak, limitJMax, lowerHullGammaInv, limitParams)
            }
            var low = gammaMinimum
            var high = low + gammaSearchStep
            var outside = false
            while !outside && high < gammaMaximum {
                if fits(high) {
                    outside = true
                } else {
                    low = high
                    high = high + gammaSearchStep
                }
            }
            while high - low > gammaAccuracy {
                let testGamma = (high + low) / 2
                if fits(testGamma) { high = testGamma } else { low = testGamma }
            }
            table[i].2 = 1 / high
        }
        table[lowerWrapIndex].2 = table[lastNominalIndex].2
        table[upperWrapIndex].2 = table[firstNominalIndex].2
        table[upperWrapIndex + 1].2 = table[firstNominalIndex + 1].2
    }

    static func hueSearchRange(_ table: [F3]) -> (Int, Int) {
        var range = (0, 1)
        for i in firstNominalIndex..<upperWrapIndex {
            let position = firstNominalIndex + Int(table[i].2)
            let delta = i - position
            range.0 = min(range.0, delta)
            range.1 = max(range.1, delta + 1)
        }
        return range
    }

    static func initGamutCompress(
        _ peak: Float, _ input: JMhParams, _ limit: JMhParams, _ ts: ToneScaleParams, _ sp: SharedCompression,
        _ reach: JMhParams
    ) -> GamutCompressParams {
        let midJ = yToJ(ts.c_t * referenceLuminance, input)
        let focusDist = focusDistance + focusDistance * focusDistanceScaling * ts.logPeak
        let lowerHullGammaInv = 1 / (1.14 + 0.07 * ts.logPeak)

        let reachCorners = findReachCorners(reach, sp.limitJMax, ts.forwardLimit)
        let limiting = buildLimitingCuspCorners(limit, peak)
        let hueTable = buildHueTable(extractSortedCubeHues(reachCorners, limiting.jmh))
        var cuspTable = buildCuspTable(hueTable, limiting.rgb, limiting.jmh, limit)
        let range = hueSearchRange(cuspTable)
        makeUpperHullGamma(hueTable, &cuspTable, peak, sp.limitJMax, midJ, focusDist, lowerHullGammaInv, limit)
        return GamutCompressParams(
            midJ: midJ, focusDist: focusDist, lowerHullGammaInv: lowerHullGammaInv, hueSearchRange: range,
            hueTable: hueTable, cuspTable: cuspTable)
    }

    // MARK: The transform

    /// As Renderer_ACES_OutputTransform20::fwd.
    func forward(_ rgb: F3) -> F3 {
        let Aab = Self.rgbToAab(rgb, pIn)
        let JMh = Self.aabToJMh(Aab, pIn)
        let rp = resolve(JMh.2)
        let h = Self.toRadians(JMh.2)
        let cosH = cosf(h)
        let sinH = sinf(h)
        let Mnorm = Self.chromaCompressNorm(cosH, sinH, chroma.chromaCompressScale)
        let J_ts = Self.tonescaleAToJFwd(Aab.0, pIn, tone)
        let tonemapped = Self.chromaCompressFwd(JMh, J_ts, Mnorm, rp, chroma)
        let compressed = gamutCompressFwd(tonemapped, rp)
        return Self.aabToRGB(Self.jmhToAab(compressed, cosH, sinH, pOut), pOut)
    }
}
