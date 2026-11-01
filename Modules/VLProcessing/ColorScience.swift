import Foundation
import VLCore
import simd

public enum ColorMath {
    public static let d65 = SIMD3<Double>(0.95047, 1, 1.08883)

    public static let xyzToRec2020 = simd_double3x3(rows: [
        SIMD3(1.7166512, -0.3556708, -0.2533663),
        SIMD3(-0.6666844, 1.6164812, 0.0157685),
        SIMD3(0.0176399, -0.0427706, 0.9421031),
    ])

    public static let rec2020ToRec709 = simd_double3x3(rows: [
        SIMD3(1.6604910, -0.5876411, -0.0728499),
        SIMD3(-0.1245505, 1.1328999, -0.0083494),
        SIMD3(-0.0181508, -0.1005789, 1.1187297),
    ])

    private static let bradfordMatrix = simd_double3x3(rows: [
        SIMD3(0.8951, 0.2664, -0.1614),
        SIMD3(-0.7502, 1.7135, 0.0367),
        SIMD3(0.0389, -0.0685, 1.0296),
    ])

    /// Chromatic adaptation between two XYZ white points.
    public static func bradford(from source: SIMD3<Double>, to target: SIMD3<Double>) -> simd_double3x3 {
        let ratio = (bradfordMatrix * target) / (bradfordMatrix * source)
        return bradfordMatrix.inverse * simd_double3x3(diagonal: ratio) * bradfordMatrix
    }

    /// McCamy's approximation of correlated color temperature.
    public static func colorTemperature(xyz: SIMD3<Double>) -> Double {
        let sum = xyz.x + xyz.y + xyz.z
        guard sum > 0 else { return 6504 }
        let n = (xyz.x / sum - 0.3320) / (0.1858 - xyz.y / sum)
        return 449 * n * n * n + 3525 * n * n + 6823.3 * n + 5520.33
    }

    static func illuminantTemperature(_ exifCode: Double?) -> Double {
        switch Int(exifCode ?? 0) {
        case 17: return 2856
        case 20: return 5503
        case 21: return 6504
        case 23: return 5003
        default: return 6504
        }
    }
}

/// The primaries a log image can be recorded in, all with a D65 white.
public enum Gamut: String, CaseIterable, Identifiable, Sendable {
    case rec2020
    case sGamut3
    case arriWideGamut3

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .rec2020: return "Rec.2020"
        case .sGamut3: return "S-Gamut3"
        case .arriWideGamut3: return "ARRI Wide Gamut 3"
        }
    }

    /// The curve this gamut belongs to. Rec.2020 goes with any curve.
    public var curve: LogCurve? {
        switch self {
        case .rec2020: return nil
        case .sGamut3: return .sLog3
        case .arriWideGamut3: return .logC3
        }
    }

    /// The gamut with what it pairs with, so a list shows which curves have their own.
    public var pairedLabel: String {
        switch self {
        case .rec2020: return "Rec.2020 · any curve"
        case .sGamut3: return "S-Gamut3 · S-Log3"
        case .arriWideGamut3: return "ARRI Wide Gamut 3 · LogC3"
        }
    }

    /// Red, green and blue as CIE xy.
    private var primaries: (red: SIMD2<Double>, green: SIMD2<Double>, blue: SIMD2<Double>)? {
        switch self {
        case .rec2020: return nil
        case .sGamut3: return (SIMD2(0.730, 0.280), SIMD2(0.140, 0.855), SIMD2(0.100, -0.050))
        case .arriWideGamut3: return (SIMD2(0.6840, 0.3130), SIMD2(0.2210, 0.8480), SIMD2(0.0861, -0.1020))
        }
    }

    /// Converts linear Rec.2020 to this gamut. Built from the published primaries.
    public var fromRec2020: simd_double3x3 {
        guard let primaries else { return matrix_identity_double3x3 }
        func xyz(_ point: SIMD2<Double>) -> SIMD3<Double> {
            SIMD3(point.x / point.y, 1, (1 - point.x - point.y) / point.y)
        }
        let unscaled = simd_double3x3(columns: (xyz(primaries.red), xyz(primaries.green), xyz(primaries.blue)))
        let scale = unscaled.inverse * ColorMath.d65
        let toXYZ = unscaled * simd_double3x3(diagonal: scale)
        return toXYZ.inverse * ColorMath.xyzToRec2020.inverse
    }
}

extension LogCurve {
    /// The gamut the curve's own cameras record. Apple Log is already Rec.2020.
    public var nativeGamut: Gamut {
        switch self {
        case .appleLog: return .rec2020
        case .sLog3: return .sGamut3
        case .logC3: return .arriWideGamut3
        }
    }
}

/// The DNG color model for one camera: converts white-balanced camera RGB to linear Rec.2020.
public struct CameraCalibration: Sendable {
    private let matrix1: simd_double3x3
    private let matrix2: simd_double3x3
    private let temperature1: Double
    private let temperature2: Double

    public init?(_ metadata: DNGMetadata) {
        guard let first = Self.matrix(metadata.colorMatrix1) ?? Self.matrix(metadata.colorMatrix2) else {
            return nil
        }
        matrix1 = first
        matrix2 = Self.matrix(metadata.colorMatrix2) ?? first
        temperature1 = ColorMath.illuminantTemperature(metadata.calibrationIlluminant1?.first)
        temperature2 = ColorMath.illuminantTemperature(metadata.calibrationIlluminant2?.first)
    }

    private static func matrix(_ values: [Double]?) -> simd_double3x3? {
        guard let v = values, v.count == 9 else { return nil }
        return simd_double3x3(rows: [
            SIMD3(v[0], v[1], v[2]), SIMD3(v[3], v[4], v[5]), SIMD3(v[6], v[7], v[8]),
        ])
    }

    /// Blends the two matrices in reciprocal temperature, as the DNG specification does.
    private func colorMatrix(temperature: Double) -> simd_double3x3 {
        guard temperature1 != temperature2 else { return matrix1 }
        let low = 1 / temperature1
        let high = 1 / temperature2
        let weight = min(max((1 / temperature - high) / (low - high), 0), 1)
        return matrix1 * weight + matrix2 * (1 - weight)
    }

    /// `neutral` is the camera RGB of a white object. The result maps (1, 1, 1) after white
    /// balance to Rec.2020 white, adapting the scene white to D65.
    public func balancedToRec2020(neutral: SIMD3<Double>) -> simd_double3x3 {
        var temperature = 5003.0
        var matrix = colorMatrix(temperature: temperature)
        for _ in 0..<6 {
            matrix = colorMatrix(temperature: temperature)
            temperature = max(ColorMath.colorTemperature(xyz: matrix.inverse * neutral), 2000)
        }
        var cameraToXYZ = matrix.inverse * simd_double3x3(diagonal: neutral)
        var white = cameraToXYZ * SIMD3(repeating: 1)
        cameraToXYZ = cameraToXYZ * (1 / white.y)
        white /= white.y
        return ColorMath.xyzToRec2020 * ColorMath.bradford(from: white, to: ColorMath.d65) * cameraToXYZ
    }
}
