import Foundation

/// Builds the PHP document root from the read-only app bundle.
///
/// Folders that contain code (.php/.tpl) become real, writable folders with the code files copied – TravianZ
/// writes next to its code (GameEngine/config.php, Prevention/, Notes/, var/log, Templates/text.tpl,
/// the installer renames install/). Everything else (images, gpack, css, js) is symlinked to the bundle.
///
/// After an app update the document root is rebuilt; the game state listed in `statePaths` survives it.
enum GameFiles {
    static let copiedExtensions: Set<String> = ["php", "tpl", "inc", "sql", "json", "txt", "log", "lock", "lck", "html"]

    /// Files and folders TravianZ writes at runtime (see game/.gitignore) – kept across app updates.
    static let statePaths = [
        "GameEngine/config.php",
        "GameEngine/Admin/Mods/constant_format.tpl",
        "var/installed",
        "var/log",
        "GameEngine/Prevention",
        "GameEngine/Notes",
        "Templates/text.tpl",
    ]

    static func prepare() throws {
        let fm = FileManager.default
        for dir in [Paths.support, Paths.run, Paths.sessions, Paths.logs, Paths.tmp] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let buildID = (try? String(contentsOf: Paths.bundledGame.appendingPathComponent(".build-id"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "dev"
        let marker = Paths.support.appendingPathComponent("www.build-id")
        if (try? String(contentsOf: marker, encoding: .utf8)) != buildID || !fm.fileExists(atPath: Paths.www.path) {
            try keepState()
            try? fm.removeItem(at: Paths.www)
            try fm.createDirectory(at: Paths.www, withIntermediateDirectories: true)
            try mirror(from: Paths.bundledGame, to: Paths.www)
            try restoreState()
            try buildID.write(to: marker, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: Paths.mysqlData.appendingPathComponent("mysql").path) {
            try? fm.removeItem(at: Paths.mysqlData)
            try fm.copyItem(at: Paths.mariadbTemplate, to: Paths.mysqlData)
        }
    }

    /// True when the installer finished in this document root.
    static var isInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: Paths.www.appendingPathComponent("var/installed").path)
            && fm.fileExists(atPath: Paths.www.appendingPathComponent("GameEngine/config.php").path)
    }

    private static func keepState() throws {
        let fm = FileManager.default
        try? fm.removeItem(at: Paths.stateKeep)
        guard fm.fileExists(atPath: Paths.www.path) else { return }
        for path in statePaths {
            let src = Paths.www.appendingPathComponent(path)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = Paths.stateKeep.appendingPathComponent(path)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: src, to: dst)
        }
    }

    private static func restoreState() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Paths.stateKeep.path) else { return }
        for path in statePaths {
            let src = Paths.stateKeep.appendingPathComponent(path)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = Paths.www.appendingPathComponent(path)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dst)
            try fm.moveItem(at: src, to: dst)
        }
        try? fm.removeItem(at: Paths.stateKeep)
    }

    private static func mirror(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        for item in items {
            let name = item.lastPathComponent
            if name == ".build-id" || name == ".DS_Store" { continue }
            let target = dst.appendingPathComponent(name)
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if containsCode(item) || isEmpty(item) {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    try mirror(from: item, to: target)
                } else {
                    try fm.createSymbolicLink(at: target, withDestinationURL: item)
                }
            } else if copiedExtensions.contains(item.pathExtension.lowercased()) || name.hasPrefix(".") {
                try fm.copyItem(at: item, to: target)
            } else {
                try fm.createSymbolicLink(at: target, withDestinationURL: item)
            }
        }
    }

    private static func containsCode(_ dir: URL) -> Bool {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return false }
        for case let url as URL in e where ["php", "tpl"].contains(url.pathExtension.lowercased()) { return true }
        return false
    }

    private static func isEmpty(_ dir: URL) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty
    }
}
