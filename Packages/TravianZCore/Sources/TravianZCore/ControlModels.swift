import Foundation

/// Responses of the local control endpoint /__tz/<action> (ios/runtime/control.php).

public struct HealthResponse: Decodable, Sendable {
    public var status: String
    public var php: String?
    public var isReady: Bool { status == "ready" }
}

public struct ServerStatus: Decodable, Sendable {
    public struct Database: Decodable, Sendable {
        public var ok: Bool
        public var version: String?
        public var error: String?
        public var tables: Int?
    }
    public var ok: Bool
    public var installed: Bool
    public var config: Bool?
    public var installer: Bool?
    public var php: String?
    public var settings: [String: String?]?
    public var db: Database?
    public var users: Int?
    public var villages: Int?
    public var tiles: Int?

    public func setting(_ name: String) -> String? { settings?[name] ?? nil }
}

public struct TickResult: Decodable, Sendable {
    public var ok: Bool
    public var ran: Bool?
    public var ms: Int?
    public var error: String?
    public var output: String?
}

public struct SQLResponse: Decodable, Sendable {
    public struct ResultSet: Decodable, Sendable {
        public var columns: [String]
        public var rows: [[String]]
    }
    public var ok: Bool?
    public var sets: [ResultSet]?
    public var affected: Int?
    public var error: String?
    public var ms: Int?

    public init(ok: Bool? = nil, sets: [ResultSet]? = nil, affected: Int? = nil, error: String? = nil, ms: Int? = nil) {
        self.ok = ok; self.sets = sets; self.affected = affected; self.error = error; self.ms = ms
    }

    public var lastSet: ResultSet? { sets?.last }
}

public struct SimpleResponse: Decodable, Sendable {
    public var ok: Bool
    public var error: String?
    public var changed: [String]?
    public var dropped: Int?
}

public struct StartNowResponse: Decodable, Sendable {
    public var ok: Bool
    public var moved: Bool?
    public var start: String?
    public var error: String?
}
