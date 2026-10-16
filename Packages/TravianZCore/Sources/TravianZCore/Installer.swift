import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Runs the TravianZ web installer (install/) over HTTP, step by step, like a person clicking through it.
/// Mirror of scripts/tz_install.py.
public struct Installer: Sendable {
    public var baseURL: URL
    public var settings: WorldSettings
    public var database: DatabaseCredentials
    public var adminPassword: String
    public var adminName = "Admin"
    public var timeZone = TimeZone.current.identifier

    public init(baseURL: URL, settings: WorldSettings, database: DatabaseCredentials, adminPassword: String) {
        self.baseURL = baseURL
        self.settings = settings
        self.database = database
        self.adminPassword = adminPassword
    }

    public struct Failure: LocalizedError {
        public let step: String
        public let detail: String
        public var errorDescription: String? { "Instalace (\(step)): \(detail)" }
    }

    /// Installs the world. `progress` gets a short Czech description of each step.
    public func run(progress: @escaping @Sendable (String) -> Void) async throws {
        let config = URLSessionConfiguration.ephemeral        // private cookie jar for the installer session
        config.httpCookieAcceptPolicy = .always
        config.timeoutIntervalForRequest = 1800
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let base = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString

        progress("Instalace 1/6: konfigurace")
        var (url, text) = try await request(session, base + "/install/index.php?s=1")
        if text.contains("Installation appears to have been completed") { return }
        let defaults = InstallForm.defaults(in: text)
        guard defaults["subconst"] != nil else { throw Failure(step: "konfigurace", detail: "formulář nenalezen") }
        let form = settings.installerForm(defaults: defaults, baseURL: base, database: database, timeZone: timeZone)
        (url, text) = try await request(session, base + "/install/process.php", form: form)
        try expect(url, "s=2", "konfigurace", text)

        progress("Instalace 2/6: tabulky databáze")
        (url, text) = try await request(session, base + "/install/process.php", form: ["substruc": "1"])
        try expect(url, "s=3", "tabulky", text)

        progress("Instalace 3/6: mapa \(settings.worldMax * 2 + 1)×\(settings.worldMax * 2 + 1)")
        (url, text) = try await request(session, base + "/install/process.php", form: ["subwdata": "1"])
        try expect(url, "startCroppers=1", "mapa", text)

        progress("Instalace 4/6: obilná pole")
        (_, text) = try await request(session, base + "/install/ajax_croppers.php")
        let last = Self.lastEvent(ofStream: text)
        if last == nil || last?["error"] as? Bool == true || ((last?["pct"] as? Int) ?? 0) < 100 {
            throw Failure(step: "obilná pole", detail: (last?["msg"] as? String) ?? String(text.prefix(300)))
        }

        progress("Instalace 5/6: účty")
        (url, text) = try await request(session, base + "/install/include/accounts.php", form: [
            "mhpw": adminPassword, "spw": adminPassword, "aname": adminName, "aemail": "admin@localhost",
            "apass": adminPassword, "atribe": "1", "admin_rank": "false",
            "admin_support_msgs": "true", "admin_raidable": "false",
        ])
        try expect(url, "s=5", "účty", text)

        progress("Instalace 6/6: dokončení")
        if !text.contains("Installation Complete") {          // the redirect after the accounts usually ran it
            (_, text) = try await request(session, base + "/install/index.php?s=5")
            guard text.contains("Installation Complete") else {
                throw Failure(step: "dokončení", detail: Self.plain(text))
            }
        }
    }

    /// Last `data: {…}` event of a server-sent-events body.
    static func lastEvent(ofStream text: String) -> [String: Any]? {
        text.split(separator: "\n").reversed().lazy
            .filter { $0.hasPrefix("data: {") }
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.dropFirst(6).utf8)) as? [String: Any] }
            .first
    }

    static func plain(_ html: String) -> String {
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(stripped.trimmingCharacters(in: .whitespaces).prefix(400))
    }

    private func expect(_ url: URL?, _ fragment: String, _ step: String, _ text: String) throws {
        guard let url, url.absoluteString.contains(fragment) else {
            throw Failure(step: step, detail: "skončilo na \(url?.absoluteString ?? "?"): \(Self.plain(text))")
        }
    }

    private func request(_ session: URLSession, _ url: String, form: [String: String]? = nil) async throws -> (URL?, String) {
        var req = URLRequest(url: URL(string: url)!)
        if let form {
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(FormEncoding.encode(form).utf8)
        }
        let (data, response) = try await session.data(for: req)
        return (response.url, String(decoding: data, as: UTF8.self))
    }
}

public enum FormEncoding {
    private static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    public static func component(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
    public static func encode(_ form: [String: String]) -> String {
        form.sorted { $0.key < $1.key }.map { "\(component($0.key))=\(component($0.value))" }.joined(separator: "&")
    }
}
