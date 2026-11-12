import Foundation

/// A whole grade as the export screen holds it: the look, how a LUT expects its input, the
/// adjustments and the effects. Exports and baked takes keep one in their sidecar's metadata,
/// under `metadataKey`, so a later export can copy it. The export screen also keeps the one being
/// worked on in `export_grade.json` until an export with it succeeds.
public struct GradeRecipe: Codable, Equatable, Sendable {
    /// Empty for the Monitor (Rec.709) view, or a look's name.
    public var look: String
    public var lutMadeForRec709: Bool
    public var grade: LookGrade
    public var effects: LookEffects

    public static let metadataKey = "gradeRecipe"

    public init(look: String, lutMadeForRec709: Bool = false, grade: LookGrade = LookGrade(), effects: LookEffects = LookEffects()) {
        self.look = look
        self.lutMadeForRec709 = lutMadeForRec709
        self.grade = grade
        self.effects = effects
    }

    /// No adjustment and no effect, whatever the look.
    public var isNeutral: Bool { grade.isNeutral && effects.isNeutral }

    /// One line for a list: the look, then what was changed.
    public var summary: String {
        var parts = [look.isEmpty ? "Monitor (Rec.709)" : look]
        if !grade.isNeutral { parts.append("graded") }
        if !effects.isNeutral { parts.append("FX") }
        return parts.joined(separator: ", ")
    }

    /// Compact JSON, for a sidecar's string metadata.
    public var metadataValue: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The recipe a sidecar's metadata holds, if it holds one.
    public static func from(metadata: [String: String]?) -> GradeRecipe? {
        guard let text = metadata?[metadataKey], let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GradeRecipe.self, from: data)
    }

    // MARK: The export screen's grade in progress

    public static var savedURL: URL { Storage.documents.appendingPathComponent("export_grade.json") }

    public static func loadSaved() -> GradeRecipe? {
        guard let data = try? Data(contentsOf: savedURL) else { return nil }
        return try? JSONDecoder().decode(GradeRecipe.self, from: data)
    }

    /// Writes it, or removes the file for nil.
    public static func save(_ recipe: GradeRecipe?) {
        guard let recipe else {
            try? FileManager.default.removeItem(at: savedURL)
            return
        }
        if let data = try? JSONEncoder().encode(recipe) { try? data.write(to: savedURL, options: .atomic) }
    }
}
