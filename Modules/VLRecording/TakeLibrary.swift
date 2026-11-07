import Foundation
import VLCore

/// A finished recording, with what its sidecar says about it. Older or failed takes may have none.
public struct Take: Identifiable, Sendable {
    public let url: URL
    public let bytes: Int
    public let date: Date?
    public let info: VideoEncoder.Result?

    public var id: URL { url }

    /// The video and, when there is one, its gyro log.
    public var files: [URL] {
        let gyro = TakeLibrary.gyroLog(for: url)
        return FileManager.default.fileExists(atPath: gyro.path) ? [url, gyro] : [url]
    }
}

/// The encoded takes in the videos folder.
public enum TakeLibrary {
    public static func sidecar(for url: URL) -> URL { url.appendingPathExtension("json") }

    /// The first free name for an export of `take` in `folder`: `<take>_look.mov`, then
    /// `<take>_look2.mov` and on, so a new export never replaces an earlier one.
    public static func exportURL(for take: URL, in folder: URL) -> URL {
        let base = take.deletingPathExtension().lastPathComponent + "_look"
        var number = 1
        while true {
            let url = folder.appendingPathComponent(base + (number == 1 ? "" : String(number)) + ".mov")
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            number += 1
        }
    }

    /// Whether a file is an export rather than a take, from its name.
    public static func isExport(_ url: URL) -> Bool {
        url.deletingPathExtension().lastPathComponent.range(of: #"_look\d*$"#, options: .regularExpression) != nil
    }

    /// Gyroflow finds a log with the video's name by itself.
    public static func gyroLog(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("gcsv")
    }

    public static func captureTiming(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("timing.csv")
    }

    public static func take(at url: URL) -> Take {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
        let info = (try? Data(contentsOf: sidecar(for: url))).flatMap {
            try? JSONDecoder().decode(VideoEncoder.Result.self, from: $0)
        }
        return Take(url: url, bytes: values?.fileSize ?? 0, date: values?.creationDate, info: info)
    }

    /// Newest first. Names sort by time.
    public static func takes(in folder: URL = Storage.videos) -> [Take] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey])) ?? []
        return files.filter { $0.pathExtension == "mov" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map(take(at:))
    }

    /// A take without a sidecar or gyro log still deletes.
    public static func delete(_ take: Take) throws {
        try FileManager.default.removeItem(at: take.url)
        try? FileManager.default.removeItem(at: sidecar(for: take.url))
        try? FileManager.default.removeItem(at: gyroLog(for: take.url))
        try? FileManager.default.removeItem(at: captureTiming(for: take.url))
    }
}
