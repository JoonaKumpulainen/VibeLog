import Foundation
import VLCore

/// Connects to the owner's test server on a private network, takes commands and sends files.
/// The phone always starts each request, so the app opens no port of its own.
///
/// A take comes first: this runs on its own low-priority queue, files wait until the take ends, and
/// only one idle request stays open during it. It's off at every launch.
final class TestLink {
    /// Runs on the main queue. Call the closure with the reply.
    var onCommand: ((TestCommand, @escaping (TestReply) -> Void) -> Void)?
    /// Runs on the main queue with a short description of the connection.
    var onState: ((String) -> Void)?

    private static let longPollSeconds = 20

    private let queue = DispatchQueue(label: "vibelog.test-link", qos: .utility)
    private let session: URLSession
    private var base: URL?
    private var token = ""
    /// Each start gets a new number, so a request from before a stop ends its loop.
    private var generation = 0
    private var pending: [(name: String, source: Upload)] = []
    private var sending = false
    private var holdingFiles = false

    private enum Upload {
        case file(URL)
        case data(Data)
    }

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = TimeInterval(Self.longPollSeconds + 15)
        configuration.timeoutIntervalForResource = 3600
        session = URLSession(configuration: configuration)
    }

    func start(base: URL, token: String) {
        queue.async { [self] in
            generation += 1
            self.base = base
            self.token = token
            report("Connecting")
            poll(generation)
        }
    }

    func stop() {
        queue.async { [self] in
            generation += 1
            base = nil
            pending = []
            report("Off")
        }
    }

    /// Files sent during a take wait for its end.
    func holdFiles(_ hold: Bool) {
        queue.async { [self] in
            holdingFiles = hold
            sendNext()
        }
    }

    func send(file: URL, name: String? = nil) {
        queue.async { [self] in
            guard base != nil else { return }
            pending.append((name ?? file.lastPathComponent, .file(file)))
            sendNext()
        }
    }

    func send(data: Data, name: String) {
        queue.async { [self] in
            guard base != nil else { return }
            pending.append((name, .data(data)))
            sendNext()
        }
    }

    private func report(_ state: String) {
        guard let onState else { return }
        DispatchQueue.main.async { onState(state) }
    }

    private func request(_ path: String, query: [URLQueryItem] = []) -> URLRequest? {
        guard let base, var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { return nil }
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // ngrok's free tunnels can answer with a warning page instead of the server; this skips it.
        request.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")
        return request
    }

    private func poll(_ run: Int) {
        guard run == generation, let request = request(
            "next", query: [URLQueryItem(name: "wait", value: String(Self.longPollSeconds))])
        else { return }
        session.dataTask(with: request) { [weak self] data, response, error in
            self?.queue.async { self?.finishPoll(run, data: data, response: response, error: error) }
        }.resume()
    }

    private func finishPoll(_ run: Int, data: Data?, response: URLResponse?, error: Error?) {
        guard run == generation else { return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            report("Token refused")
            return
        }
        guard error == nil, status == 200 || status == 204 else {
            report("Waiting for the server")
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.poll(run) }
            return
        }
        report("Connected")
        guard status == 200, let data, let command = try? JSONDecoder().decode(TestCommand.self, from: data) else {
            poll(run)
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let onCommand = self.onCommand else { return }
            onCommand(command) { reply in
                self.queue.async {
                    self.send(reply)
                    self.poll(run)
                }
            }
        }
    }

    private func send(_ reply: TestReply) {
        guard var request = request("reply"), let body = try? JSONEncoder().encode(reply) else { return }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        session.uploadTask(with: request, from: body).resume()
    }

    private func sendNext() {
        guard !sending, !holdingFiles, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        guard var request = request("upload", query: [URLQueryItem(name: "name", value: next.name)]) else { return }
        request.httpMethod = "POST"
        sending = true
        let done: (Data?, URLResponse?, Error?) -> Void = { [weak self] _, _, error in
            if let error { Log.shared.warn("Test link couldn't send \(next.name): \(error.localizedDescription)") }
            self?.queue.async {
                self?.sending = false
                self?.sendNext()
            }
        }
        switch next.source {
        case .file(let url): session.uploadTask(with: request, fromFile: url, completionHandler: done).resume()
        case .data(let data): session.uploadTask(with: request, from: data, completionHandler: done).resume()
        }
    }
}
