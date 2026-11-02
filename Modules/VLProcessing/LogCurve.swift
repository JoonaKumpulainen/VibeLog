import Foundation

/// Log encodings of scene-linear reflectance, where 0.18 is middle gray. Constants match
/// colour-science's implementations of the vendor formulas. Shaders.metal holds the same
/// encoders for the GPU, and a GPU test compares the two.
public enum LogCurve: UInt32, CaseIterable, Identifiable, Sendable {
    case appleLog = 0
    case sLog3 = 1
    case logC3 = 2
    /// Apple Log's curve, recorded in Apple Wide Gamut instead of Rec.2020.
    case appleLog2 = 3

    public var id: UInt32 { rawValue }

    public var label: String {
        switch self {
        case .appleLog: return "Apple Log"
        case .sLog3: return "S-Log3"
        case .logC3: return "LogC3 (EI 800)"
        case .appleLog2: return "Apple Log 2"
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
