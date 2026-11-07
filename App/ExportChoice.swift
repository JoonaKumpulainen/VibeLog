import Foundation
import VLCore
import VLProcessing
import VLRecording

/// How much HEVC an export spends on a 12 MP picture.
enum ExportQuality: String, CaseIterable, Identifiable, Sendable {
    case master, high, share

    var id: String { rawValue }

    var megabits: Double {
        switch self {
        case .master: return 200
        case .high: return 100
        case .share: return 40
        }
    }

    var label: String {
        switch self {
        case .master: return "Master"
        case .high: return "High"
        case .share: return "Share"
        }
    }
}

/// The long side an export shrinks to, or the take's own.
enum ExportResolution: String, CaseIterable, Identifiable, Sendable {
    case full, medium, small

    var id: String { rawValue }

    var longSide: Int? {
        switch self {
        case .full: return nil
        case .medium: return 2880
        case .small: return 1920
        }
    }

    var label: String { longSide.map { "\($0) wide" } ?? "Full" }
}

/// The shape an export is cropped to, as it plays upright.
enum ExportCrop: String, CaseIterable, Identifiable, Sendable {
    case none, wide, tall

    var id: String { rawValue }

    /// Width over height as it plays, or nil to keep the take's.
    var aspect: Double? {
        switch self {
        case .none: return nil
        case .wide: return 16.0 / 9
        case .tall: return 9.0 / 16
        }
    }

    var label: String {
        switch self {
        case .none: return "None"
        case .wide: return "16:9"
        case .tall: return "9:16"
        }
    }
}

/// What an export bakes in, shared by the export screen and the test link, so both build the
/// same look and write the same label.
struct ExportChoice: Sendable {
    /// Empty for Monitor's Rec.709 view, or a look's name.
    var lutName = BuiltInLook.aces20.name
    var lutMadeForRec709 = false
    var grade = LookGrade()
    var effects = LookEffects()
    /// Only ACES 2.0 bakes HDR.
    var target = BakeTarget.sdr
    var codec = "hevc420"
    /// HEVC's rate. ProRes keeps its own.
    var quality = ExportQuality.master
    var resolution = ExportResolution.full
    var crop = ExportCrop.none

    static let codecs = ["hevc420", "prores422lt", "prores422", "prores422hq"]

    /// The codec at its own rate, before the size of the picture sets HEVC's.
    private var basePreset: EncoderPreset {
        if codec == EncoderPreset.proRes422LT.id { return EncoderPreset.proRes422LT }
        return EncoderPreset.all.first { $0.id == codec } ?? EncoderPreset.all[0]
    }

    /// The preset for a picture this size. HEVC's rate is the quality's at 12 MP, falling with the
    /// pixels to the power 0.75, so a smaller picture keeps the same look per pixel, about.
    func preset(width: Int, height: Int) -> EncoderPreset {
        let base = basePreset
        guard base.bitrate != nil else { return base }
        let share = Double(width * height) / Double(4032 * 3024)
        return base.withBitrate(Int(quality.megabits * 1_000_000 * pow(share, 0.75)))
    }

    /// The encoder's size: the stored picture cropped to the shape chosen as it plays, upright, then
    /// shrunk to the resolution's long side, kept to even numbers.
    func outputSize(width: Int, height: Int, quarterTurns: Int) -> (width: Int, height: Int) {
        var w = Double(width)
        var h = Double(height)
        if let aspect = crop.aspect {
            // A take held upright is stored sideways, so its shape turns with it.
            let stored = quarterTurns % 2 == 0 ? aspect : 1 / aspect
            if w / h > stored { w = h * stored } else { h = w / stored }
        }
        if let long = resolution.longSide, max(w, h) > Double(long) {
            let scale = Double(long) / max(w, h)
            w *= scale
            h *= scale
        }
        return (Int((w / 2).rounded()) * 2, Int((h / 2).rounded()) * 2)
    }

    /// Size, resolution and crop, for the log and the sidecar.
    func formatLabel(width: Int, height: Int) -> String {
        let preset = preset(width: width, height: height)
        let rate = preset.bitrate.map { " at \($0 / 1_000_000) Mb/s" } ?? ""
        return "\(preset.label)\(rate), \(width)x\(height)" + (crop == .none ? "" : ", cropped \(crop.label)")
    }

    var hdr: BakeTarget? { lutName == BuiltInLook.aces20.name && target.isHDR ? target : nil }

    var fileTag: FileTag { hdr == .hlg ? .hlg : hdr == .pq ? .pq : .rec709 }

    var label: String {
        let graded = (grade.isNeutral ? "" : ", graded (\(grade.label))")
            + (effects.isNeutral ? "" : ", effects (\(effects.label))")
        let lutLabel = lutName.isEmpty
            ? "Rec.709 view\(graded), baked in"
            : BuiltInLook.named(lutName) != nil ? "\(lutName) Rec.709\(graded), baked in"
            : "\(lutName)\(graded), baked in" + (lutMadeForRec709 ? " after the Rec.709 view" : " on log")
        return hdr.map { "ACES 2.0 HDR 1000 nits, \($0 == .hlg ? "HLG" : "PQ")" + lutLabel.dropFirst("ACES 2.0 Rec.709".count) }
            ?? lutLabel
    }

    /// The take's own curve and gamut, as its sidecar names them.
    static func curve(of take: Take) -> LogCurve {
        LogCurve.allCases.first { $0.label == take.info?.metadata["curve"] } ?? .appleLog
    }

    static func gamut(of take: Take) -> Gamut {
        Gamut.allCases.first { $0.label == take.info?.metadata["gamut"] } ?? curve(of: take).nativeGamut
    }

    static func sourceRec709(_ take: Take) -> Bool { take.info?.metadata["fileTag"] == FileTag.rec709.label }

    /// A take recorded with a look baked in has no log left to convert.
    static func isLog(_ take: Take) -> Bool {
        guard let look = take.info?.metadata["look"] else { return true }
        return look == "log, as recorded"
    }

    /// The LUT size an export's look is built at: 129 points a side against the viewfinder's 65,
    /// since CI run 87 measured the 65-point ACES LUT up to 0.06 to 0.10 off between grid points in
    /// saturated colours. An export isn't held to the frame rate, so it can take the second or so
    /// a 129-point build needs, and the GPU still does one lookup a pixel.
    static let exportLUTSize = 129

    /// The look for playback, without HDR. Reading a .cube or building an ACES look takes a
    /// moment, so this belongs off the main thread.
    func previewLook(curve: LogCurve, gamut: Gamut, sourceRec709: Bool) -> LookExporter.Look {
        var look = gradedLook(curve: curve, gamut: gamut, sourceRec709: sourceRec709, size: 65)
        look.effects = effects
        return look
    }

    /// The look the export writes, HDR included, at the export's finer LUT size.
    func exportLook(curve: LogCurve, gamut: Gamut, sourceRec709: Bool) -> LookExporter.Look {
        var look: LookExporter.Look
        if let hdr {
            look = LookExporter.Look(
                curve: curve, gamut: gamut,
                lut: BuiltInLook.hdrLUT(curve: curve, gamut: gamut, grade: grade, target: hdr, size: Self.exportLUTSize),
                lutExpectsRec709: false, sourceRec709: sourceRec709)
            look.hdr = true
        } else {
            look = gradedLook(curve: curve, gamut: gamut, sourceRec709: sourceRec709, size: Self.exportLUTSize)
        }
        look.effects = effects
        return look
    }

    private func gradedLook(curve: LogCurve, gamut: Gamut, sourceRec709: Bool, size: Int) -> LookExporter.Look {
        if let builtIn = BuiltInLook.named(lutName) {
            return LookExporter.Look(
                curve: curve, gamut: gamut, lut: builtIn.lut(curve: curve, gamut: gamut, grade: grade, size: size),
                lutExpectsRec709: false, sourceRec709: sourceRec709)
        }
        if lutName.isEmpty, !grade.isNeutral {
            return LookExporter.Look(
                curve: curve, gamut: gamut, lut: BuiltInLook.rec709LUT(curve: curve, gamut: gamut, grade: grade, size: size),
                lutExpectsRec709: false, sourceRec709: sourceRec709)
        }
        var lut: CubeLUT?
        if !lutName.isEmpty {
            let url = Storage.luts.appendingPathComponent(lutName)
            lut = (try? String(contentsOf: url, encoding: .utf8)).flatMap { try? CubeLUT(text: $0) }
            if lut == nil { Log.shared.warn("Export: can't read the LUT \(lutName), baking the Rec.709 view alone") }
        }
        if let cube = lut, !grade.isNeutral {
            return LookExporter.Look(
                curve: curve, gamut: gamut,
                lut: BuiltInLook.graded(
                    cube, expectsRec709: lutMadeForRec709, curve: curve, gamut: gamut, grade: grade, size: size),
                lutExpectsRec709: false, sourceRec709: sourceRec709)
        }
        return LookExporter.Look(
            curve: curve, gamut: gamut, lut: lut, lutExpectsRec709: lutMadeForRec709, sourceRec709: sourceRec709)
    }
}
