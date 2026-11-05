import Foundation
import VLCore
import VLProcessing
import VLRecording

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

    var preset: EncoderPreset { EncoderPreset.all.first { $0.id == codec } ?? EncoderPreset.all[0] }

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

    /// The look for playback, without HDR. Reading a .cube or building an ACES look takes a
    /// moment, so this belongs off the main thread.
    func previewLook(curve: LogCurve, gamut: Gamut, sourceRec709: Bool) -> LookExporter.Look {
        var look = gradedLook(curve: curve, gamut: gamut, sourceRec709: sourceRec709)
        look.effects = effects
        return look
    }

    /// The look the export writes, HDR included.
    func exportLook(curve: LogCurve, gamut: Gamut, sourceRec709: Bool) -> LookExporter.Look {
        var look = previewLook(curve: curve, gamut: gamut, sourceRec709: sourceRec709)
        if let hdr {
            look.lut = BuiltInLook.hdrLUT(curve: curve, gamut: gamut, grade: grade, target: hdr)
            look.lutExpectsRec709 = false
            look.hdr = true
        }
        return look
    }

    private func gradedLook(curve: LogCurve, gamut: Gamut, sourceRec709: Bool) -> LookExporter.Look {
        if let builtIn = BuiltInLook.named(lutName) {
            return LookExporter.Look(
                curve: curve, gamut: gamut, lut: builtIn.lut(curve: curve, gamut: gamut, grade: grade),
                lutExpectsRec709: false, sourceRec709: sourceRec709)
        }
        if lutName.isEmpty, !grade.isNeutral {
            return LookExporter.Look(
                curve: curve, gamut: gamut, lut: BuiltInLook.rec709LUT(curve: curve, gamut: gamut, grade: grade),
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
                lut: BuiltInLook.graded(cube, expectsRec709: lutMadeForRec709, curve: curve, gamut: gamut, grade: grade),
                lutExpectsRec709: false, sourceRec709: sourceRec709)
        }
        return LookExporter.Look(
            curve: curve, gamut: gamut, lut: lut, lutExpectsRec709: lutMadeForRec709, sourceRec709: sourceRec709)
    }
}
