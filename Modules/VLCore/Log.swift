import Combine
import Foundation

private var crashFD: Int32 = -1

private func writeCrash(_ text: StaticString) {
    guard crashFD >= 0 else { return }
    _ = write(crashFD, text.utf8Start, text.utf8CodeUnitCount)
}

private func crashSignalHandler(_ signalNumber: Int32) {
    writeCrash("\n*** FATAL SIGNAL ")
    var digits: [UInt8] = [
        UInt8(48 + (signalNumber / 10) % 10), UInt8(48 + signalNumber % 10), 10,
    ]
    _ = write(crashFD, &digits, 3)
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}

/// In-app log, mirrored line by line to Documents/logs so a crash leaves a readable trail.
public final class Log: ObservableObject {
    public static let shared = Log()

    public enum Level: String {
        case info = "I"
        case warn = "W"
        case error = "E"
    }

    @Published public private(set) var lines: [String] = []
    @Published public private(set) var errorCount = 0
    @Published public private(set) var lastError: String?

    public let fileURL: URL
    public let previousFileURL: URL?

    private let queue = DispatchQueue(label: "vibelog.log")
    private let maxLines = 3000
    private let clock: DateFormatter

    private init() {
        let existing = (try? FileManager.default.contentsOfDirectory(
            at: Storage.logs, includingPropertiesForKeys: nil)) ?? []
        previousFileURL = existing.filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.last
        fileURL = Storage.logs.appendingPathComponent("session_\(Storage.timestamp()).log")
        crashFD = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "HH:mm:ss.SSS"
    }

    /// Installs handlers that record fatal exceptions and signals in the log file.
    public func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            let text = "\n*** UNCAUGHT \(exception.name.rawValue): \(exception.reason ?? "")\n"
                + exception.callStackSymbols.prefix(30).joined(separator: "\n") + "\n"
            _ = text.withCString { write(crashFD, $0, strlen($0)) }
        }
        for number in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(number, crashSignalHandler)
        }
    }

    public func info(_ message: String) { add(.info, message) }
    public func warn(_ message: String) { add(.warn, message) }
    public func error(_ message: String) { add(.error, message) }

    public func text() -> String { lines.joined(separator: "\n") }

    private func add(_ level: Level, _ message: String) {
        queue.async { [self] in
            let line = "\(clock.string(from: Date())) \(level.rawValue) \(message)"
            let bytes = Array((line + "\n").utf8)
            _ = write(crashFD, bytes, bytes.count)
            DispatchQueue.main.async { [self] in
                lines.append(line)
                if lines.count > maxLines {
                    lines.removeFirst(lines.count - maxLines)
                }
                if level == .error {
                    errorCount += 1
                    lastError = message
                }
            }
        }
    }
}
