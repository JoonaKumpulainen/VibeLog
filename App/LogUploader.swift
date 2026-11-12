import Foundation
import Network
import UIKit
import VLCore

/// Sends test logs to the owner's log service, when the tester has turned it on. It never runs
/// during a take, only on Wi-Fi unless the tester allows mobile data, never in Low Data Mode, and
/// only sends what's new
/// or grown since the last time. Everything is made anonymous by `LogSanitizer` first.
/// See docs/decisions/log-service.md.
final class LogUploader: ObservableObject {
    @Published private(set) var settings = LogSharingSettings.load()
    @Published private(set) var busy = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "log-uploader", qos: .utility)
    /// The current network: connected at all, metered (mobile data or a hotspot), Low Data Mode.
    private var connected = false
    private var metered = true
    private var lowData = false
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.allowsConstrainedNetworkAccess = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.connected = path.status == .satisfied
                self?.metered = path.isExpensive
                self?.lowData = path.isConstrained
            }
        }
        monitor.start(queue: queue)
    }

    /// Changes the settings and saves them. Turning sharing off stops nothing already sent.
    func update(_ change: (inout LogSharingSettings) -> Void) {
        change(&settings)
        settings.save()
    }

    var stateText: String {
        if busy { return "Sending…" }
        if !settings.on { return "Off" }
        if settings.inviteCode.isEmpty || settings.server.isEmpty { return "Needs a server and an invite code" }
        if !settings.lastResult.isEmpty { return settings.lastResult }
        return settings.mobileData ? "Waiting for a connection" : "Waiting for Wi-Fi"
    }

    /// Sends what's new, if sharing is on and nothing stands in the way. `names` are the names
    /// the owner typed, of LUTs, presets and styles, which are taken out of every file.
    func sendIfDue(recording: Bool, names: [String], reason: String, completion: (() -> Void)? = nil) {
        let settings = self.settings
        guard settings.on, !settings.inviteCode.isEmpty, let base = URL(string: settings.server),
              base.scheme == "https", !recording, !busy
        else { completion?(); return }
        let waiting = !connected ? (settings.mobileData ? "Waiting for a connection" : "Waiting for Wi-Fi")
            : lowData ? "Waiting: Low Data Mode is on"
            : (metered && !settings.mobileData) ? "Waiting for Wi-Fi" : nil
        if let waiting {
            update { $0.lastResult = waiting }
            completion?()
            return
        }
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            let outcome = self.send(settings: settings, base: base, names: names)
            DispatchQueue.main.async {
                self.busy = false
                self.update { now in
                    for (path, size) in outcome.sent { now.sent[path] = size }
                    if !outcome.sent.isEmpty { now.lastUpload = Date() }
                    now.lastResult = outcome.message
                }
                Log.shared.info("Log sharing (\(reason)): \(outcome.message)")
                completion?()
            }
        }
    }

    private struct Outcome {
        var sent: [String: Int] = [:]
        var message = ""
    }

    /// Runs on the uploader's queue, one batch at a time, and stops at the first refusal.
    private func send(settings: LogSharingSettings, base: URL, names: [String]) -> Outcome {
        let documents = Storage.documents
        let files = LogSharing.changed(LogSharing.candidates(documents: documents, gyro: settings.gyro), sent: settings.sent)
        guard !files.isEmpty else { return Outcome(message: "Up to date") }
        var outcome = Outcome()
        let model = SystemStatus.deviceModel
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let ios = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let app = SystemStatus.appVersion
        for batch in LogSharing.batches(files) {
            let items: [[String: String]] = batch.compactMap { file in
                guard let data = try? Data(contentsOf: documents.appendingPathComponent(file.path)) else { return nil }
                let text = String(decoding: data, as: UTF8.self)
                return ["name": LogSanitizer.uploadName(for: file.path, salt: settings.salt),
                        "text": LogSanitizer.clean(text, salt: settings.salt, privateNames: names)]
            }
            guard !items.isEmpty else { continue }
            let body: [String: Any] = [
                "install": settings.installID, "model": model, "ios": ios, "app": app, "files": items,
            ]
            var request = URLRequest(url: base.appendingPathComponent("upload"))
            request.httpMethod = "POST"
            request.allowsExpensiveNetworkAccess = settings.mobileData
            request.allowsConstrainedNetworkAccess = false
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(settings.inviteCode)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            let (status, error) = post(request)
            switch status {
            case 200:
                for file in batch { outcome.sent[file.path] = file.size }
            case 401:
                outcome.message = "Invite code refused"
                return outcome
            case 429:
                outcome.message = "Sent \(outcome.sent.count) files; the rest next time"
                return outcome
            default:
                outcome.message = "Couldn't send: \(error ?? "status \(status)")"
                return outcome
            }
        }
        outcome.message = "Sent \(outcome.sent.count) files"
        return outcome
    }

    private func post(_ request: URLRequest) -> (Int, String?) {
        let done = DispatchSemaphore(value: 0)
        var status = 0
        var failure: String?
        session.dataTask(with: request) { _, response, error in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            failure = error?.localizedDescription
            done.signal()
        }.resume()
        done.wait()
        return (status, failure)
    }
}
