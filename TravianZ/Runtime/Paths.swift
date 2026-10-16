import Foundation
import TravianZCore

/// Everything writable lives in Application Support/TravianZ; logs in Documents/logs (visible in the Files app).
enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TravianZ", isDirectory: true)
    }()
    /// Document root of the PHP server: a writable mirror of the bundled game (code copied, images symlinked).
    static var www: URL { support.appendingPathComponent("www", isDirectory: true) }
    static var mysqlData: URL { support.appendingPathComponent("mariadb", isDirectory: true) }
    static var run: URL { support.appendingPathComponent("run", isDirectory: true) }
    static var sessions: URL { support.appendingPathComponent("sessions", isDirectory: true) }
    /// Game state kept aside while the document root is rebuilt after an app update.
    static var stateKeep: URL { support.appendingPathComponent("state-keep", isDirectory: true) }
    static var secrets: URL { support.appendingPathComponent("secrets.json") }
    static var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tz", isDirectory: true) }

    static var logs: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("logs", isDirectory: true)
    }
    /// Written before each start step and removed once the game runs: if it exists at launch, the previous
    /// start was killed (for example MariaDB aborting the process).
    static var startMarker: URL { logs.appendingPathComponent("last-start.txt") }
    static var serverLog: URL { logs.appendingPathComponent("server.log") }
    static var phpErrorLog: URL { logs.appendingPathComponent("php-errors.log") }
    static var mariadbLog: URL { logs.appendingPathComponent("mariadb.log") }
    static var tickLog: URL { logs.appendingPathComponent("automation.log") }
    static var setupLog: URL { logs.appendingPathComponent("setup.log") }
    static var gameAccessLog: URL { www.appendingPathComponent("var/log/access.log") }

    static var bundledGame: URL { Bundle.main.resourceURL!.appendingPathComponent("game", isDirectory: true) }
    static var bundledRuntime: URL { Bundle.main.resourceURL!.appendingPathComponent("runtime", isDirectory: true) }
    static var mariadbShare: URL { Bundle.main.resourceURL!.appendingPathComponent("mariadb-share", isDirectory: true) }
    static var mariadbTemplate: URL { Bundle.main.resourceURL!.appendingPathComponent("mariadb-template", isDirectory: true) }

    /// Unix socket paths are limited to 104 bytes. On an iPhone the app's tmp folder is
    /// /private/var/mobile/Containers/Data/Application/<UUID>/tmp/ (89 bytes), so the file name must stay short –
    /// and /tmp is NOT writable there. Only the simulator (long container path, unsandboxed /tmp) uses /tmp.
    static let socket: String = {
        let p = NSTemporaryDirectory() + "m.sock"
        if p.utf8.count <= 100 { return p }
        #if targetEnvironment(simulator)
        return "/tmp/tz-\(getuid())-m.sock"
        #else
        return p
        #endif
    }()
}

/// Generated once per installation.
struct Secrets: Codable {
    var adminPassword: String
    var controlToken: String

    /// Must match ios/mariadb/make-template.sh (the bundled data directory).
    static let database = DatabaseCredentials(user: "travianz", password: "travianz-ios-local", name: "travianz")

    static func load() -> Secrets {
        if let data = try? Data(contentsOf: Paths.secrets), let s = try? JSONDecoder().decode(Secrets.self, from: data) {
            return s
        }
        let s = Secrets(adminPassword: random(12), controlToken: random(32))
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        try? JSONEncoder().encode(s).write(to: Paths.secrets, options: .atomic)
        return s
    }

    static func random(_ n: Int) -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        return String((0..<n).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }
}
