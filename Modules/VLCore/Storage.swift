import Foundation

/// Folders inside Documents, all visible in the Files app.
public enum Storage {
    public static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    public static var clips: URL { folder("clips") }
    public static var logs: URL { folder("logs") }
    public static var probes: URL { folder("probes") }
    public static var stills: URL { folder("stills") }
    public static var videos: URL { folder("videos") }
    public static var luts: URL { folder("luts") }
    public static var config: URL { documents.appendingPathComponent("VibeLog.config.json") }
    public static var benchmarks: URL { documents.appendingPathComponent("benchmarks.csv") }

    public static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: date)
    }

    private static func folder(_ name: String) -> URL {
        let url = documents.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
