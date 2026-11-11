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
    /// Colour and luminance for shadows, midtones and highlights, in `ToneRange` order.
    public var wheels = [ToneWheel](repeating: ToneWheel(), count: ToneRange.allCases.count)

    public init() {}

    public var isNeutral: Bool { self == LookGrade() }

    /// Whether each page of the grade holds a change: ADJUST's five values, COLOR's bands and
    /// the wheels.
    public var adjustChanged: Bool {
        let neutral = LookGrade()
        return exposure != neutral.exposure || contrast != neutral.contrast || temperature != neutral.temperature
            || tint != neutral.tint || saturation != neutral.saturation
    }
    public var colorChanged: Bool { !bands.allSatisfy(\.isNeutral) }
    public var wheelsChanged: Bool { !wheels.allSatisfy(\.isNeutral) }

    /// The values that differ from neutral, as the sidecar and Details name them.
    public var label: String {
        var parts: [String] = []
        if exposure != 0 { parts.append(String(format: "exposure %+.1f", exposure)) }
        if contrast != 0 { parts.append(String(format: "contrast %+.0f", contrast * 100)) }
        if temperature != 0 { parts.append(String(format: "temperature %+.0f", temperature * 100)) }
        if tint != 0 { parts.append(String(format: "tint %+.0f", tint * 100)) }
        if saturation != 1 { parts.append(String(format: "saturation %.0f%%", saturation * 100)) }
        for range in ToneRange.allCases where !wheels[range.rawValue].isNeutral {
            parts.append("\(range.name) \(wheels[range.rawValue].label)")
        }
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
        let savedWheels = (try? values.decodeIfPresent([ToneWheel].self, forKey: .wheels)) ?? nil
        if let savedWheels, savedWheels.count == ToneRange.allCases.count { wheels = savedWheels }
    }
}

/// The parts of the picture the wheels work on, by brightness against middle gray. They overlap
/// softly and always add up to the whole picture.
public enum ToneRange: Int, CaseIterable, Identifiable, Sendable {
    case shadows, midtones, highlights

    public var id: Int { rawValue }

    public var name: String {
        switch self {
        case .shadows: return "shadows"
        case .midtones: return "midtones"
        case .highlights: return "highlights"
        }
    }
}

/// One wheel: a colour push, where `x` and `y` are a point in the wheel's disc, along Oklab's
/// a and b axes, and a luminance change, -1 to 1, of up to a stop.
public struct ToneWheel: Codable, Equatable, Sendable {
    public var x = 0.0
    public var y = 0.0
    public var luminance = 0.0

    public init() {}

    public var isNeutral: Bool { self == ToneWheel() }

    /// How far the puck is from the middle, 0 to 1.
    public var amount: Double { min((x * x + y * y).squareRoot(), 1) }

    /// The push's direction in Oklab hue degrees, 0 to 360.
    public var hue: Double {
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    var label: String {
        var parts: [String] = []
        if amount > 0 { parts.append(String(format: "colour %.0f at hue %.0f", amount * 100, hue)) }
        if luminance != 0 { parts.append(String(format: "luminance %+.0f", luminance * 100)) }
        return parts.joined(separator: " ")
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

    /// Whether the style sits under a look in the carousel. The built-in styles go with both ACES
    /// looks; a saved one goes with the look it was saved on.
    public func belongs(to look: String) -> Bool {
        isBuiltIn ? look.hasPrefix("ACES ") : look == self.look
    }

    /// Saved names never take a built-in one, so the name alone tells.
    public var isBuiltIn: Bool { Self.builtIn.contains { $0.name == name } }

    /// Starting points under the ACES looks, kept gentle, to be tuned on the phone.
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

/// The FX tab: glows from highlights, a soft mist, corners and grain, applied in linear light
/// before the look. Each is 0 to 1, and vignette -1 to 1, where below 0 lightens the corners.
public struct LookEffects: Codable, Equatable, Sendable {
    public var halation = 0.0
    public var bloom = 0.0
    public var diffusion = 0.0
    public var vignette = 0.0
    public var grain = 0.0

    public init() {}

    public var isNeutral: Bool { self == LookEffects() }

    public var label: String {
        let parts = [("halation", halation), ("bloom", bloom), ("diffusion", diffusion), ("vignette", vignette), ("grain", grain)]
            .filter { $0.1 != 0 }
            .map { "\($0.0) " + String(format: "%+.0f", $0.1 * 100) }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func read(_ key: CodingKeys) -> Double { ((try? values.decodeIfPresent(Double.self, forKey: key)) ?? nil) ?? 0 }
        halation = read(.halation)
        bloom = read(.bloom)
        diffusion = read(.diffusion)
        vignette = read(.vignette)
        grain = read(.grain)
    }
}
