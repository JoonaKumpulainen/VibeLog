import Foundation
import VLCore

/// A finished recording, with what its sidecar says about it. Older or failed takes may have none.
public struct Take: Identifiable, Sendable {
    public let url: URL
    public let bytes: Int
    public let date: Date?
    public let info: VideoEncoder.Result?

    public var id: URL { url }
}

/// The encoded takes in the videos folder.
public enum TakeLibrary {
    public static func sidecar(for url: URL) -> URL { url.appendingPathExtension("json") }

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

    /// A take with no sidecar still deletes.
    public static func delete(_ take: Take) throws {
        try FileManager.default.removeItem(at: take.url)
        try? FileManager.default.removeItem(at: sidecar(for: take.url))
    }
}
