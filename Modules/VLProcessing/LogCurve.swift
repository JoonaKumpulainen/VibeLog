import Foundation

/// Log encodings of scene-linear reflectance, where 0.18 is middle gray. Constants match
/// colour-science's implementations of the vendor formulas. Shaders.metal holds the same
/// encoders for the GPU, and a GPU test compares the two.
public enum LogCurve: UInt32, CaseIterable, Identifiable, Sendable {
    // Raw values are what the shader switches on. Settings save the label, so the order here is
    // only the order of the lists.
    case appleLog = 0
    /// Apple Log's curve, recorded in Apple Wide Gamut instead of Rec.2020.
    case appleLog2 = 3
    case sLog3 = 1
    case sLog2 = 4
    case logC3 = 2
    case logC4 = 5
    case canonLog3 = 6

    public var id: UInt32 { rawValue }

    public var label: String {
        switch self {
        case .appleLog: return "Apple Log"
        case .sLog3: return "S-Log3"
        case .logC3: return "LogC3 (EI 800)"
        case .appleLog2: return "Apple Log 2"
        case .sLog2: return "S-Log2"
        case .logC4: return "LogC4"
        case .canonLog3: return "Canon Log 3"
        }
    }

    public func encode(_ x: Double) -> Double {
        switch self {
        case .appleLog, .appleLog2:
            if x >= Apple.rt { return Apple.gamma * log2(x + Apple.beta) + Apple.delta }
            if x >= Apple.r0 { return Apple.sigma * (x - Apple.r0) * (x - Apple.r0) }
            return 0
        case .sLog3:
            if x >= Sony.cut { return (420 + log10((x + 0.01) / 0.19) * 261.5) / 1023 }
            return (x * (Sony.knee - 95) / Sony.cut + 95) / 1023
        case .logC3:
            if x > Arri.cut { return Arri.c * log10(Arri.a * x + Arri.b) + Arri.d }
            return Arri.e * x + Arri.f
        case .sLog2:
            // S-Log's formula on a scaled input, then moved into legal range.
            let x = x / 0.9 * 155 / 219
            let y = x >= 0 ? 0.432699 * log10(x + 0.037584) + 0.646596 : x * 5 + SonyLog2.linearOffset
            return (y * 876 + 64) / 1023
        case .logC4:
            if x >= Arri4.t { return (log2(Arri4.a * x + 64) - 6) / 14 * Arri4.b + Arri4.c }
            return (x - Arri4.t) / Arri4.s
        case .canonLog3:
            // Version 1.2, whose constants are already code values.
            let x = x / 0.9
            if x < -Canon.cut { return -Canon.slope * log10(-x * Canon.scale + 1) + 0.12783901 }
            if x <= Canon.cut { return 1.9754798 * x + 0.12512219 }
            return Canon.slope * log10(x * Canon.scale + 1) + 0.12240537
        }
    }

    public func decode(_ y: Double) -> Double {
        switch self {
        case .appleLog, .appleLog2:
            let knee = Apple.sigma * (Apple.rt - Apple.r0) * (Apple.rt - Apple.r0)
            if y >= knee { return pow(2, (y - Apple.delta) / Apple.gamma) - Apple.beta }
            if y >= 0 { return (y / Apple.sigma).squareRoot() + Apple.r0 }
            return Apple.r0
        case .sLog3:
            if y >= Sony.knee / 1023 { return pow(10, (y * 1023 - 420) / 261.5) * 0.19 - 0.01 }
            return (y * 1023 - 95) * Sony.cut / (Sony.knee - 95)
        case .logC3:
            if y > Arri.e * Arri.cut + Arri.f { return (pow(10, (y - Arri.d) / Arri.c) - Arri.b) / Arri.a }
            return (y - Arri.f) / Arri.e
        case .sLog2:
            let y = (y * 1023 - 64) / 876
            let x = y >= SonyLog2.linearOffset
                ? pow(10, (y - 0.646596) / 0.432699) - 0.037584 : (y - SonyLog2.linearOffset) / 5
            return x * 219 / 155 * 0.9
        case .logC4:
            if y >= 0 { return (pow(2, 14 * (y - Arri4.c) / Arri4.b + 6) - 64) / Arri4.a }
            return y * Arri4.s + Arri4.t
        case .canonLog3:
            let x: Double
            if y < LogCurve.canonLog3.encode(-Canon.cut * 0.9) {
                x = -(pow(10, (0.12783901 - y) / Canon.slope) - 1) / Canon.scale
            } else if y <= LogCurve.canonLog3.encode(Canon.cut * 0.9) {
                x = (y - 0.12512219) / 1.9754798
            } else {
                x = (pow(10, (y - 0.12240537) / Canon.slope) - 1) / Canon.scale
            }
            return x * 0.9
        }
    }

    private enum Apple {
        static let r0 = -0.05641088
        static let rt = 0.01
        static let sigma = 47.28711236
        static let beta = 0.00964052
        static let gamma = 0.08550479
        static let delta = 0.69336945
    }

    private enum Sony {
        static let cut = 0.01125
        static let knee = 171.2102946929
    }

    private enum SonyLog2 {
        static let linearOffset = 0.030001222851889303
    }

    private enum Arri4 {
        static let a = (pow(2.0, 18) - 16) / 117.45
        static let b = (1023.0 - 95) / 1023
        static let c = 95.0 / 1023
        static let s = 7 * log(2.0) * pow(2.0, 7 - 14 * c / b) / (a * b)
        static let t = (pow(2.0, 14 * -c / b + 6) - 64) / a
    }

    private enum Canon {
        static let cut = 0.014
        static let slope = 0.36726845
        static let scale = 14.98325
    }

    private enum Arri {
        static let cut = 0.010591
        static let a = 5.555556
        static let b = 0.052272
        static let c = 0.247190
        static let d = 0.385537
        static let e = 5.367655
        static let f = 0.092809
    }
}
