import Foundation

/// One instruction from the test server. Actions are a fixed list in the app, so the server can't
/// ask for anything else.
public struct TestCommand: Codable, Equatable, Sendable {
    public var id: Int
    public var action: String
    public var name: String?
    public var value: String?
    public var seconds: Double?

    public init(id: Int, action: String, name: String? = nil, value: String? = nil, seconds: Double? = nil) {
        self.id = id
        self.action = action
        self.name = name
        self.value = value
        self.seconds = seconds
    }
}

public struct TestReply: Codable, Equatable, Sendable {
    public var id: Int
    public var ok: Bool
    public var message: String
    public var values: [String: String]

    public init(id: Int, ok: Bool, message: String, values: [String: String] = [:]) {
        self.id = id
        self.ok = ok
        self.message = message
        self.values = values
    }
}

public enum TestLinkAddress {
    public static let defaultPort = 8765

    /// Turns what was typed into a server URL. On the local network, a bare address is plain HTTP on
    /// port 8765. Over the internet, only an `https://` address is taken, such as an ngrok tunnel's,
    /// on HTTPS's own port, so a plain address never leaves the network by mistake.
    public static func base(_ text: String, overInternet: Bool = false) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let secure = trimmed.lowercased().hasPrefix("https://")
        guard !trimmed.isEmpty, secure == overInternet,
            overInternet || !trimmed.contains("://") || trimmed.lowercased().hasPrefix("http://")
        else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard var parts = URLComponents(string: withScheme), parts.host?.isEmpty == false else { return nil }
        parts.scheme = secure ? "https" : "http"
        if parts.port == nil, !secure { parts.port = defaultPort }
        parts.path = ""
        parts.query = nil
        return parts.url
    }

    /// Reads "0.5,0.25" as a share of the picture.
    public static func point(_ text: String) -> (x: Double, y: Double)? {
        let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, parts.allSatisfy({ (0...1).contains($0) }) else { return nil }
        return (parts[0], parts[1])
    }

    /// Keeps a file name from reaching outside the folder it's looked up in.
    public static func safeName(_ text: String) -> String? {
        let name = (text as NSString).lastPathComponent
        return name.isEmpty || name == "." || name == ".." || name == "/" ? nil : name
    }
}
