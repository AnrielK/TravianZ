import Foundation
import Darwin
import Observation
import PHPCore
import MariaDBCore
import TravianZCore

/// Runs MariaDB (ov_mariadbd_main → mysqld_main) and PHP's built-in web server (php_cli_main) on background
/// threads, installs the world on first launch through the TravianZ web installer and drives the automation
/// (cron.php) every two seconds through the control endpoint.
@Observable
@MainActor
final class GameRuntime {
    static let shared = GameRuntime()

    enum State: Equatable {
        case idle
        case working(String)
        case running
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var port = 8080
    private(set) var lastTick = ""
    private(set) var tickCount = 0
    private(set) var tickErrors = 0
    var tickEnabled = true
    /// Set when the previous launch died during start-up (step + end of mariadb.log).
    var previousCrash: String? = nil
    /// Bumped when something changes what the pages look like (graphic pack, language, new world).
    private(set) var reloadToken = 0
    let secrets = Secrets.load()
    private(set) var world = WorldSettings.load()

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/")! }
    func url(_ path: String) -> URL { URL(string: path, relativeTo: baseURL)!.absoluteURL }

    @ObservationIgnored private var mariadbStarted = false
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var tickInFlight = false

    init() {
        if let step = try? String(contentsOf: Paths.startMarker, encoding: .utf8) {
            let tail = (try? String(contentsOf: Paths.mariadbLog, encoding: .utf8))?
                .split(separator: "\n").suffix(12).joined(separator: "\n") ?? ""
            previousCrash = "Předchozí spuštění skončilo v kroku: \(step.trimmingCharacters(in: .whitespacesAndNewlines))\n\n\(tail)"
            appendLog(Paths.setupLog, "\(Date()) previous start died at: \(step)")
        }
    }

    // MARK: start

    nonisolated static func mark(_ step: String) {
        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        try? step.write(to: Paths.startMarker, atomically: true, encoding: .utf8)
    }

    func start() {
        switch state {
        case .working, .running: return
        case .idle, .failed: break
        }
        state = .working("Připravuji soubory…")
        port = Self.requestedPort() ?? (Self.isPortOpen(8080) ? Int.random(in: 49152...60000) : 8080)
        let port = self.port
        let alreadyStarted = mariadbStarted
        Task.detached(priority: .userInitiated) {
            do {
                Self.mark("příprava souborů")
                try GameFiles.prepare()
                Self.redirectStdio()
                Self.mark("start PHP")
                // PHP first: it captures the process working directory as its (virtual, ZTS) cwd at startup.
                FileManager.default.changeCurrentDirectoryPath(Paths.www.path)
                await self.launchPHP(port: port)
                try await Self.wait("PHP server", seconds: 30) { Self.isPortOpen(port) }
                if !alreadyStarted {
                    await self.setState(.working("Spouštím databázi…"))
                    Self.mark("start MariaDB (socket \(Paths.socket))")
                    await self.launchMariaDB()
                    try await Self.wait("MariaDB", seconds: 90) { Self.isSocketOpen(Paths.socket) }
                }
                Self.mark("instalace / kontrola světa")
                try await self.ensureInstalled()
                try? FileManager.default.removeItem(at: Paths.startMarker)
                await self.setState(.running)
                await self.startTicker()
            } catch {
                appendLog(Paths.setupLog, "\(Date()) start failed: \(error.localizedDescription)")
                await self.setState(.failed(error.localizedDescription))
            }
        }
    }

    private func setState(_ s: State) { state = s }

    /// After returning from the background iOS may have closed the listening socket.
    func ensureRunning() {
        guard state == .running, !Self.isPortOpen(port) else { return }
        state = .idle
        start()
    }

    // MARK: world

    /// Installs the world through the web installer when needed, then applies the live settings.
    private func ensureInstalled() async throws {
        state = .working("Kontroluji svět…")
        let health: HealthResponse = try await control("health", timeout: 30)
        if !health.isReady {
            let status: ServerStatus? = try? await control("status", timeout: 60)
            appendLog(Paths.setupLog, "\(Date()) not installed; tables=\(status?.db?.tables ?? -1) config=\(status?.config ?? false)")
            if (status?.db?.tables ?? 0) > 0 || status?.config == true || status?.installer == false {
                // an interrupted installation: start from scratch
                let r: SimpleResponse = try await control("reset", form: [:], timeout: 600)
                guard r.ok else { throw RuntimeError("reset: \(r.error ?? "?")") }
            }
            let installer = Installer(baseURL: baseURL, settings: world, database: Secrets.database,
                                      adminPassword: secrets.adminPassword)
            let tiles = world.tiles
            try await installer.run { message in
                appendLog(Paths.setupLog, "\(Date()) \(message)")
                Task { @MainActor in
                    GameRuntime.shared.state = .working("\(message)\n\nPrvní spuštění trvá déle (mapa má \(tiles) polí).")
                }
            }
            appendLog(Paths.setupLog, "\(Date()) installed")
        }
        try await applyLiveSettings()
    }

    /// Writes speed, graphic pack, language and the current URL into config.php (read on every request).
    func applyLiveSettings() async throws {
        let r: SimpleResponse = try await control("configure", form: world.liveDefines(baseURL: baseURL.absoluteString))
        if !r.ok { throw RuntimeError("configure: \(r.error ?? "?")") }
    }

    func updateSettings(_ new: WorldSettings) async {
        let looksChanged = new.graphicPack != world.graphicPack || new.language != world.language
        world = new
        new.save()
        guard state == .running else { return }
        do {
            try await applyLiveSettings()
            if looksChanged { reloadToken += 1 }
        } catch {
            appendLog(Paths.setupLog, "\(Date()) settings: \(error.localizedDescription)")
        }
    }

    /// Drops all game data and installs a new world with the current settings (map size, new functions).
    func newWorld() async throws {
        tickEnabled = false
        defer { tickEnabled = true }
        state = .working("Mažu svět…")
        let r: SimpleResponse = try await control("reset", form: [:], timeout: 900)
        guard r.ok else {
            state = .running
            throw RuntimeError(r.error ?? "reset selhal")
        }
        do {
            try await ensureInstalled()
            state = .running
            reloadToken += 1
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    // MARK: control endpoint (ios/runtime/control.php)

    func control<T: Decodable>(_ action: String, form: [String: String]? = nil, timeout: TimeInterval = 120) async throws -> T {
        var req = URLRequest(url: url("__tz/\(action)"))
        req.timeoutInterval = timeout
        req.setValue(secrets.controlToken, forHTTPHeaderField: "X-TZ-Token")
        if let form {
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(FormEncoding.encode(form).utf8)
        }
        let (data, _) = try await URLSession.shared.data(for: req)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RuntimeError("\(action): \(String(decoding: data.prefix(400), as: UTF8.self))")
        }
    }

    func sql(_ query: String) async -> SQLResponse {
        do {
            return try await control("sql", form: ["query": query], timeout: 300)
        } catch {
            return SQLResponse(ok: false, error: error.localizedDescription)
        }
    }

    // MARK: automation tick (replaces the server cron job)

    private func startTicker() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in await GameRuntime.shared.tick() }
        }
    }

    func tick() async {
        guard tickEnabled, state == .running, !tickInFlight else { return }
        tickInFlight = true
        defer { tickInFlight = false }
        guard let r: TickResult = try? await control("tick", timeout: 300) else { return }
        tickCount += 1
        if !r.ok || r.error != nil {
            tickErrors += 1
            let line = "\(Self.stamp()) \(r.ms ?? 0) ms  ERROR \(r.error ?? "?") \(r.output ?? "")"
            lastTick = line
            appendLog(Paths.tickLog, line)
        } else {
            lastTick = "\(Self.stamp()) \(r.ms ?? 0) ms" + (r.output.map { "  " + $0 } ?? "")
            if (r.ms ?? 0) > 1000 || r.output != nil { appendLog(Paths.tickLog, lastTick) }
        }
    }

    // MARK: threads

    private func launchMariaDB() {
        mariadbStarted = true
        try? FileManager.default.removeItem(atPath: Paths.socket)
        try? FileManager.default.removeItem(at: Paths.run.appendingPathComponent("mariadbd.pid"))
        let args: [String] = [
            "mariadbd", "--no-defaults",
            "--datadir=\(Paths.mysqlData.path)",
            "--socket=\(Paths.socket)",
            "--skip-networking",
            "--pid-file=\(Paths.run.appendingPathComponent("mariadbd.pid").path)",
            "--log-error=\(Paths.mariadbLog.path)",
            "--tmpdir=\(Paths.tmp.path)",
            "--basedir=\(Bundle.main.resourcePath!)",
            "--lc-messages-dir=\(Paths.mariadbShare.path)",
            "--character-sets-dir=\(Paths.mariadbShare.appendingPathComponent("charsets").path)/",
            "--character-set-server=utf8mb4", "--collation-server=utf8mb4_unicode_ci",
            "--lower-case-table-names=1",          // must match ios/mariadb/make-template.sh
            "--sql-mode=",                         // like docker-compose.yml (command: --sql_mode="")
            "--skip-name-resolve", "--skip-stack-trace",
            // InnoDB reserves address space for innodb_buffer_pool_size_max up front; the default is derived
            // from RAM and iOS refuses such a mapping ("Cannot map …").
            "--innodb-buffer-pool-size=48M", "--innodb-buffer-pool-size-max=64M",
            "--innodb-log-file-size=16M",
            "--innodb-flush-log-at-trx-commit=2",
            "--max-connections=40", "--table-open-cache=400", "--thread-cache-size=8",
            "--key-buffer-size=4M", "--aria-pagecache-buffer-size=8M",
            "--tmp-table-size=16M", "--max-heap-table-size=32M",
        ]
        let thread = Thread {
            var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
            cargs.append(nil)
            let code = ov_mariadbd_main(Int32(args.count), &cargs)
            fputs("[TravianZ] mysqld_main returned \(code)\n", stderr)
        }
        thread.name = "mariadbd"
        thread.stackSize = 16 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func launchPHP(port: Int) {
        let db = Secrets.database
        let env: [String: String] = [
            "TZ_CONTROL_TOKEN": secrets.controlToken,
            "TZ_DB_HOST": "localhost", "TZ_DB_USER": db.user, "TZ_DB_PASSWORD": db.password, "TZ_DB_NAME": db.name,
            "TMPDIR": Paths.tmp.path,
        ]
        for (k, v) in env { setenv(k, v, 1) }
        let args: [String] = [
            "php", "-n",
            "-d", "mysqli.default_socket=\(Paths.socket)",
            "-d", "pdo_mysql.default_socket=\(Paths.socket)",
            "-d", "display_errors=0",
            "-d", "log_errors=1",
            "-d", "error_log=\(Paths.phpErrorLog.path)",
            "-d", "error_reporting=E_ALL & ~E_DEPRECATED",
            "-d", "memory_limit=512M",
            "-d", "max_execution_time=0",
            "-d", "post_max_size=8M",
            "-d", "upload_max_filesize=8M",
            "-d", "date.timezone=\(TimeZone.current.identifier)",
            "-d", "session.save_path=\(Paths.sessions.path)",
            "-d", "session.cookie_httponly=1",
            "-d", "session.cookie_samesite=Lax",
            "-d", "expose_php=0",
            "-d", "default_charset=UTF-8",
            "-d", "sendmail_path=/usr/bin/false",
            "-S", "127.0.0.1:\(port)",
            "-t", Paths.www.path,
            Paths.bundledRuntime.appendingPathComponent("router.php").path,
        ]
        let thread = Thread {
            var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
            cargs.append(nil)
            let code = php_cli_main(Int32(args.count), &cargs)
            for p in cargs { free(p) }
            fputs("[TravianZ] php_cli_main returned \(code)\n", stderr)
            Task { @MainActor in
                if GameRuntime.shared.state == .running { GameRuntime.shared.state = .failed("PHP skončil (kód \(code)).") }
            }
        }
        thread.name = "php-server"
        thread.stackSize = 16 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    // MARK: helpers

    nonisolated private static func requestedPort() -> Int? {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-port"), i + 1 < args.count { return Int(args[i + 1]) }
        return nil
    }

    nonisolated private static func wait(_ what: String, seconds: Double, _ ok: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if ok() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw RuntimeError("\(what) se nespustil – podrobnosti v Logy.")
    }

    nonisolated static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    /// stdout/stderr (PHP's access log, fatal errors) go to logs/server.log.
    nonisolated private static func redirectStdio() {
        let path = Paths.serverLog.path
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > 5_000_000 {
            try? FileManager.default.removeItem(atPath: path)
        }
        freopen(path, "a", stderr)
        freopen(path, "a", stdout)
        setvbuf(stderr, nil, _IONBF, 0)
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    nonisolated static func isPortOpen(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return r == 0
    }

    nonisolated static func isSocketOpen(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return r == 0
    }
}

struct RuntimeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func appendLog(_ url: URL, _ line: String) {
    let data = Data((line + "\n").utf8)
    if let h = try? FileHandle(forWritingTo: url) {
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
    } else {
        try? data.write(to: url)
    }
}
