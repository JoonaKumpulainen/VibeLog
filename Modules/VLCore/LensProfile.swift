import Foundation

/// What VibeLog knows about one lens of this phone at one picture size: Apple's factory
/// calibration where the phone gives it, or the field of view where it doesn't. Kept as a JSON file
/// per model, lens and size, such as `lenses/iPhone15,2/back-wide-4032x3024.json`, out of presets,
/// since it describes the phone and not how the owner works.
public struct LensProfile: Codable, Equatable, Sendable {
    /// The phone, as `SystemStatus.deviceModel` names it.
    public var model: String
    /// `back-wide`, `back-ultrawide` or `back-tele`.
    public var lens: String
    /// The picture size the focal length and centre are measured against.
    public var width: Int
    public var height: Int
    /// Focal length and optical centre in pixels of that size.
    public var fx: Double
    public var fy: Double
    public var cx: Double
    public var cy: Double
    /// Apple's distortion centre and lookup table, the magnification along the radius from the
    /// centre to the farthest corner, or empty where Apple gave none.
    public var distortionCenterX: Double?
    public var distortionCenterY: Double?
    public var distortionTable: [Double]
    /// Pixel size on the sensor in millimetres, if known.
    public var pixelSize: Double?
    /// Horizontal field of view in degrees, as the format reports it, plain and corrected.
    public var fieldOfView: Double
    public var correctedFieldOfView: Double?
    /// Where the focal length and centre came from, and when.
    public var source: String
    public var measured: String

    public init(
        model: String, lens: String, width: Int, height: Int, fx: Double, fy: Double, cx: Double, cy: Double,
        distortionCenterX: Double? = nil, distortionCenterY: Double? = nil, distortionTable: [Double] = [],
        pixelSize: Double? = nil, fieldOfView: Double, correctedFieldOfView: Double? = nil, source: String,
        measured: String
    ) {
        self.model = model
        self.lens = lens
        self.width = width
        self.height = height
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.distortionCenterX = distortionCenterX
        self.distortionCenterY = distortionCenterY
        self.distortionTable = distortionTable
        self.pixelSize = pixelSize
        self.fieldOfView = fieldOfView
        self.correctedFieldOfView = correctedFieldOfView
        self.source = source
        self.measured = measured
    }

    /// The file's name inside the model's folder.
    public var fileName: String { "\(lens)-\(width)x\(height).json" }

    /// Whether Apple's calibration, rather than the field of view alone, gave the focal length.
    public var isCalibrated: Bool { !distortionTable.isEmpty }

    /// A pinhole focal length from a horizontal field of view across `width` pixels, for a lens
    /// Apple gives no calibration for.
    public static func focalLength(fieldOfView degrees: Double, width: Int) -> Double {
        Double(width) / 2 / tan(degrees * .pi / 360)
    }

    /// The largest change of magnification the table describes, as a share, such as +0.021.
    public var distortionRange: Double? {
        guard let low = distortionTable.min(), let high = distortionTable.max() else { return nil }
        return abs(high) >= abs(low) ? high : low
    }

    /// This phone's folder of profiles.
    public static var folder: URL {
        let url = Storage.lenses.appendingPathComponent(SystemStatus.deviceModel, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Every profile saved for this phone, wide, ultra wide, then tele.
    public static func saved() -> [LensProfile] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let order = ["back-wide", "back-ultrawide", "back-tele"]
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(LensProfile.self, from: Data(contentsOf: $0)) }
            .sorted { (order.firstIndex(of: $0.lens) ?? 9, $0.width) < (order.firstIndex(of: $1.lens) ?? 9, $1.width) }
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.folder.appendingPathComponent(fileName), options: .atomic)
    }

    /// Deletes this phone's profiles.
    public static func removeAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}
