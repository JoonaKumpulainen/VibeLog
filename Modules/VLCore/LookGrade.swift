import Foundation

/// The owner's grade under a built-in look or the Rec.709 view, set while watching the viewfinder.
/// It's applied in scene-linear before the look's tone curve, so pushes still roll off smoothly.
/// Every value at zero, and saturation at one, leaves the look as it is.
public struct LookGrade: Codable, Equatable, Sendable {
    /// Stops.
    public var exposure = 0.0
    /// -1 to 1, around middle gray.
    public var contrast = 0.0
    /// -1 to 1, cooler to warmer.
    public var temperature = 0.0
    /// -1 to 1, greener to more magenta.
    public var tint = 0.0
    /// 0 is gray, 1 is as recorded, 2 is double.
    public var saturation = 1.0
    /// Hue, saturation and luminance for each colour, in `ColorBand` order.
    public var bands = [BandAdjust](repeating: BandAdjust(), count: ColorBand.allCases.count)

    public init() {}

    public var isNeutral: Bool { self == LookGrade() }

    /// The values that differ from neutral, as the sidecar and Details name them.
    public var label: String {
        var parts: [String] = []
        if exposure != 0 { parts.append(String(format: "exposure %+.1f", exposure)) }
        if contrast != 0 { parts.append(String(format: "contrast %+.0f", contrast * 100)) }
        if temperature != 0 { parts.append(String(format: "temperature %+.0f", temperature * 100)) }
        if tint != 0 { parts.append(String(format: "tint %+.0f", tint * 100)) }
        if saturation != 1 { parts.append(String(format: "saturation %.0f%%", saturation * 100)) }
        for band in ColorBand.allCases where !bands[band.rawValue].isNeutral {
            parts.append("\(band.name) \(bands[band.rawValue].label)")
        }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // One mistyped value must not discard the rest.
        func read(_ key: CodingKeys, _ fallback: Double) -> Double {
            ((try? values.decodeIfPresent(Double.self, forKey: key)) ?? nil) ?? fallback
        }
        exposure = read(.exposure, 0)
        contrast = read(.contrast, 0)
        temperature = read(.temperature, 0)
        tint = read(.tint, 0)
        saturation = read(.saturation, 1)
        let saved = (try? values.decodeIfPresent([BandAdjust].self, forKey: .bands)) ?? nil
        if let saved, saved.count == ColorBand.allCases.count { bands = saved }
    }
}

/// The colours the COLOR tab adjusts, each a soft range of hue. Skin is a narrower range inside
/// red and orange that leaves strong colours alone.
public enum ColorBand: Int, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, cyan, blue, magenta, skin

    public var id: Int { rawValue }

    public var name: String {
        switch self {
        case .red: return "red"
        case .orange: return "orange"
        case .yellow: return "yellow"
        case .green: return "green"
        case .cyan: return "cyan"
        case .blue: return "blue"
        case .magenta: return "magenta"
        case .skin: return "skin"
        }
    }
}

/// One colour's change, each -1 to 1: hue turns up to 30 degrees, saturation scales chroma by up
/// to double or to gray, and luminance moves up to a stop.
public struct BandAdjust: Codable, Equatable, Sendable {
    public var hue = 0.0
    public var saturation = 0.0
    public var luminance = 0.0

    public init() {}

    public var isNeutral: Bool { self == BandAdjust() }

    var label: String {
        [("hue", hue), ("saturation", saturation), ("luminance", luminance)]
            .filter { $0.1 != 0 }
            .map { "\($0.0) " + String(format: "%+.0f", $0.1 * 100) }
            .joined(separator: " ")
    }
}

/// A look and a grade under one name, shown in the LOOKS carousel. Choosing one loads its grade
/// into ADJUST and COLOR, where it can be changed further.
public struct LookStyle: Codable, Equatable, Sendable {
    public var name: String
    /// A built-in look's name, an imported LUT's file name, or empty for the Monitor view.
    public var look: String
    public var grade: LookGrade

    public init(name: String, look: String, grade: LookGrade) {
        self.name = name
        self.look = look
        self.grade = grade
    }

    /// Starting points under ACES 2.0, kept gentle, to be tuned on the phone.
    public static let builtIn: [LookStyle] = [
        style("Warm") { $0.temperature = 0.35; $0.saturation = 1.05 },
        style("Cool") { $0.temperature = -0.35; $0.tint = -0.05 },
        style("Punchy") { $0.contrast = 0.35; $0.saturation = 1.25 },
        style("Faded") { $0.contrast = -0.35; $0.saturation = 0.8; $0.exposure = 0.1 },
        style("Mono") { $0.saturation = 0; $0.contrast = 0.25 },
        style("Teal & Orange") {
            $0.contrast = 0.15
            $0.saturation = 1.05
            // Greens and blues turn toward teal, and warm colours get richer.
            $0.bands[ColorBand.green.rawValue].hue = 0.5
            $0.bands[ColorBand.blue.rawValue].hue = -0.4
            $0.bands[ColorBand.cyan.rawValue].saturation = 0.2
            $0.bands[ColorBand.orange.rawValue].saturation = 0.15
            $0.bands[ColorBand.skin.rawValue].saturation = 0.1
        },
        style("Bleach bypass") { $0.saturation = 0.45; $0.contrast = 0.45; $0.exposure = -0.1 },
    ]

    private static func style(_ name: String, _ change: (inout LookGrade) -> Void) -> LookStyle {
        var grade = LookGrade()
        change(&grade)
        return LookStyle(name: name, look: "ACES 2.0", grade: grade)
    }
}
