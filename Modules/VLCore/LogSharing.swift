import CryptoKit
import Foundation

/// Opt-in sharing of test logs with the owner's log service, `tools/log_service`. Off until the
/// tester turns it on in Diagnostics and enters an invite code. Only small text files go, never
/// videos, stills or previews, and each is made anonymous first by `LogSanitizer`.
/// See docs/decisions/log-service.md.
///
/// Kept in Application Support, apart from `AppConfig`, so presets never carry it and the
/// invite code isn't shown in the Files app.
public struct LogSharingSettings: Codable, Equatable, Sendable {
    public var on = false
    /// The `.gcsv` gyro logs too, which describe how the phone moved.
    public var gyro = false
    /// Over mobile data and hotspots too, not only Wi-Fi. Low Data Mode still stops it.
    public var mobileData = false
    public var inviteCode = ""
    public var server = LogSharing.defaultServer
    /// A random ID with nothing of the phone or its owner in it. A new one starts afresh.
    public var installID = UUID().uuidString.lowercased()
    /// Mixed into the short names that replace dates, so they can't be worked back.
    public var salt = LogSharing.newSalt()
    /// Each file's size when it was last sent, by its path inside Documents.
    public var sent: [String: Int] = [:]
    public var lastUpload: Date?
    public var lastResult = ""

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LogSharingSettings()
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? values.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        on = read(.on, defaults.on)
        gyro = read(.gyro, defaults.gyro)
        mobileData = read(.mobileData, defaults.mobileData)
        inviteCode = read(.inviteCode, defaults.inviteCode)
        server = read(.server, defaults.server)
        installID = read(.installID, defaults.installID)
        salt = read(.salt, defaults.salt)
        sent = read(.sent, defaults.sent)
        lastUpload = read(.lastUpload, defaults.lastUpload)
        lastResult = read(.lastResult, defaults.lastResult)
    }

    /// A new anonymous ID: what was sent before can no longer be linked to what's sent next.
    public mutating func startAfresh() {
        installID = UUID().uuidString.lowercased()
        salt = LogSharing.newSalt()
        sent = [:]
        lastUpload = nil
        lastResult = ""
    }

    public static var file: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("log_sharing.json")
    }

    public static func load(from url: URL = file) -> LogSharingSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(LogSharingSettings.self, from: data)
        else { return LogSharingSettings() }
        return settings
    }

    public func save(to url: URL = Self.file) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// One file that may be shared: where it is, and its size now.
public struct LogShareFile: Equatable, Sendable {
    /// Inside Documents, such as `logs/session_20261112_134734.log`.
    public let path: String
    public let size: Int

    public init(path: String, size: Int) {
        self.path = path
        self.size = size
    }
}

public enum LogSharing {
    /// The owner's service. Empty until it's deployed; the tester can enter another.
    public static let defaultServer = "https://vibelog-logs.vibelog-testing.workers.dev"
    /// A file bigger than this is left out. Session logs run to about 100 KB, probes 300 KB.
    public static let largestFile = 1_500_000
    /// One upload's files together, before compression. Logs compress about tenfold, which keeps
    /// each request well under the service's 4 MB.
    public static let batchBytes = 8_000_000
    /// Automatic uploads at most this often. Launch, a take, and **Send now** don't wait.
    public static let quietInterval: TimeInterval = 15 * 60

    /// Whether an automatic upload should go now. `reason` is "launch", "left the app" or
    /// "asked"; `tookSince` says a take finished since the last upload.
    public static func due(reason: String, lastUpload: Date?, tookSince: Bool, now: Date = Date()) -> Bool {
        if reason != "left the app" || tookSince { return true }
        guard let lastUpload else { return true }
        return now.timeIntervalSince(lastUpload) >= quietInterval
    }

    /// The files to send: the session log still being written only goes after a take or when
    /// asked, so leaving the app often doesn't resend it each time; it goes whole at the next
    /// launch otherwise.
    public static func choose(_ files: [LogShareFile], openLog: String?, sendOpenLog: Bool) -> [LogShareFile] {
        guard let openLog, !sendOpenLog else { return files }
        return files.filter { $0.path != openLog }
    }

    public static func newSalt() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Every file that may go, by its path inside Documents: session logs, exports.csv, take
    /// sidecars, gyro logs when asked, probe and test reports, lens profiles, and what the app
    /// measured about this phone. Nothing else.
    public static func candidates(documents: URL, gyro: Bool) -> [LogShareFile] {
        var paths: [String] = []
        func list(_ folder: String, recursive: Bool = false) -> [String] {
            let root = documents.appendingPathComponent(folder, isDirectory: true)
            guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
            var found: [String] = []
            while let item = walker.nextObject() as? String {
                if !recursive && item.contains("/") { continue }
                found.append(folder + "/" + item)
            }
            return found
        }
        paths += list("logs").filter { $0.hasSuffix(".log") || $0.hasSuffix("exports.csv") }
        paths += list("videos").filter { $0.hasSuffix(".mov.json") || (gyro && $0.hasSuffix(".gcsv")) }
        paths += list("probes").filter { [".txt", ".json", ".csv"].contains(where: $0.hasSuffix) }
        paths += list("lenses", recursive: true).filter { $0.hasSuffix(".json") }
        paths += ["capture_support.json", "encoder_support.json", "benchmarks.csv"]
        return paths.sorted().compactMap { path in
            let url = documents.appendingPathComponent(path)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
                  size > 0, size <= largestFile
            else { return nil }
            return LogShareFile(path: path, size: size)
        }
    }

    /// Files new since the last upload, or grown, as the current session's log does.
    public static func changed(_ files: [LogShareFile], sent: [String: Int]) -> [LogShareFile] {
        files.filter { sent[$0.path] != $0.size }
    }

    /// Groups files into uploads of at most `limit` bytes each, in order.
    public static func batches(_ files: [LogShareFile], limit: Int = batchBytes) -> [[LogShareFile]] {
        var result: [[LogShareFile]] = []
        var current: [LogShareFile] = []
        var bytes = 0
        for file in files {
            if !current.isEmpty && bytes + file.size > limit {
                result.append(current)
                current = []
                bytes = 0
            }
            current.append(file)
            bytes += file.size
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// Makes a log, sidecar or report anonymous before it leaves the phone.
///
/// - Dates in names and text, `20261112_134734`, become a short code from the install's salt,
///   the same in every file, so a log still names its take's sidecar.
/// - Full dates and times, such as a lens profile's `2026-11-12T11:56:15Z`, become `<date>`.
/// - Web and network addresses, such as the test link's server, become `<address>`.
/// - A gyro log's Unix time becomes 0.
/// - Names the owner typed, of LUTs, presets and styles, become `<name 1>` and on.
///
/// What stays: the phone model, iOS and app versions, settings, frame counts, heat, errors and
/// times of day, which are what make the logs worth reading.
public enum LogSanitizer {
    public static func code(for stamp: String, salt: String) -> String {
        let digest = SHA256.hash(data: Data((salt + stamp).utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static let stamp = try! NSRegularExpression(pattern: #"(?<![0-9])(20[0-9]{6}_[0-9]{6})(?![0-9])"#)
    private static let isoDate = try! NSRegularExpression(
        pattern: #"[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?(Z|[+-][0-9]{2}:?[0-9]{2})?"#)
    private static let url = try! NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s"'<>,)\]]+"#)
    private static let tunnelHost = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.(ngrok-free\.app|ngrok\.app|ngrok\.io|ngrok-free\.dev|trycloudflare\.com)"#)
    private static let ipv4 = try! NSRegularExpression(
        pattern: #"(?<![0-9.])[0-9]{1,3}(\.[0-9]{1,3}){3}(:[0-9]{1,5})?(?![0-9.])"#)
    private static let unixTime = try! NSRegularExpression(pattern: #"(?m)^timestamp,[0-9]+"#)

    /// The name a file goes by in an upload: its path's dates coded, folders folded into the
    /// name, so `lenses/iPhone15,2/back-wide-4032x3024.json` is `lenses_back-wide-4032x3024.json`.
    public static func uploadName(for path: String, salt: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        let name = parts.last ?? path
        let prefixed: String
        switch parts.first {
        case "lenses": prefixed = "lenses_" + name
        case "probes": prefixed = "probe_" + name
        default: prefixed = name
        }
        let coded = replacingStamps(in: prefixed, salt: salt)
        // The service takes letters, digits, dot, dash and underscore.
        return String(coded.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" }.prefix(120))
    }

    public static func clean(_ text: String, salt: String, privateNames: [String] = []) -> String {
        var out = replacingStamps(in: text, salt: salt)
        out = replace(isoDate, in: out, with: "<date>")
        out = replace(url, in: out, with: "<address>")
        out = replace(tunnelHost, in: out, with: "<address>")
        out = replace(ipv4, in: out, with: "<address>")
        out = replace(unixTime, in: out, with: "timestamp,0")
        // Longest first, so a name that contains another is replaced whole. Only whole words, and
        // only names of four letters or more, so a preset called "Night" can't touch "Nightly".
        let names = Array(Set(privateNames.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 4 }))
            .sorted { $0.count > $1.count }
        for (index, name) in names.enumerated() {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            guard let pattern = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + escaped + "(?![\\p{L}\\p{N}])")
            else { continue }
            out = replace(pattern, in: out, with: "<name \(index + 1)>")
        }
        return out
    }

    private static func replacingStamps(in text: String, salt: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var out = text
        for match in stamp.matches(in: text, range: range).reversed() {
            guard let found = Range(match.range, in: text), let target = Range(match.range, in: out) else { continue }
            out.replaceSubrange(target, with: code(for: String(text[found]), salt: salt))
        }
        return out
    }

    private static func replace(_ pattern: NSRegularExpression, in text: String, with template: String) -> String {
        pattern.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text),
            withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }
}
