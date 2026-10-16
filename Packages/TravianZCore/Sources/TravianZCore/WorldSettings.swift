import Foundation

/// World settings chosen in the app. Most of them map to `define(...)` constants in GameEngine/config.php:
/// some apply immediately (`liveDefines`), the map size and the feature switches only when a new world is created.
public struct WorldSettings: Codable, Equatable, Sendable {
    public var speed = 10
    public var troopSpeed = 1
    /// WORLD_MAX: the map goes from -worldMax to +worldMax (the installer offers these values).
    public var worldMax = 50
    public var graphicPack = "gpack/travian_default/"
    public var language = "en"
    /// Turns on every "new function" of TravianZ v11 (T4 hero, the four new tribes, alliance bonuses, …).
    public var newFunctions = true
    public var serverName = "TravianZ"

    public init() {}

    public static let worldSizes = [10, 25, 50, 100, 150, 200]
    public static let graphicPacks: [(path: String, name: String)] = [
        ("gpack/travian_default/", "Travian Default (T3.6)"),
        ("gpack/travian_t4/", "Travian T4"),
    ]
    public static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("fr", "Français"), ("it", "Italiano"), ("es", "Español"), ("ro", "Română"), ("zh", "中文"),
    ]

    /// Tiles of the map: (2·worldMax + 1)².
    public var tiles: Int { (2 * worldMax + 1) * (2 * worldMax + 1) }

    /// Constants the control endpoint may rewrite in a running world (config.php is read on every request).
    public func liveDefines(baseURL: String) -> [String: String] {
        let url = baseURL.hasSuffix("/") ? baseURL : baseURL + "/"
        return [
            "SPEED": String(max(1, speed)),
            "INCREASE_SPEED": String(max(1, troopSpeed)),
            "SERVER_GP": graphicPack,
            "SERVER_LANG": language,
            "SERVER_NAME": serverName,
            "HOMEPAGE": url, "SERVER": url, "DOMAIN": url,
        ]
    }

    /// Values sent with the installer's config form on top of the form's own defaults.
    public func installerOverrides(baseURL: String, database: DatabaseCredentials, timeZone: String) -> [String: String] {
        let url = baseURL.hasSuffix("/") ? baseURL : baseURL + "/"
        return [
            "servername": serverName,
            "tzone": "0," + timeZone,
            "speed": String(max(1, speed)),
            "incspeed": String(max(1, troopSpeed)),
            "wmax": String(worldMax),
            "lang": language,
            "sserver": "localhost", "sport": "3306",
            "suser": database.user, "spass": database.password, "sdb": database.name, "prefix": "s1_",
            "server": url, "domain": url, "homepage": url,
            // the app ticks the automation itself (control endpoint) – one tick per invocation
            "cron_loop": "0", "cron_tick": "15",
            "gp_locate": graphicPack,
            "gpack": "true",
        ]
    }

    /// The installer form with defaults, overrides and (optionally) every new function switched on.
    public func installerForm(defaults: [String: String], baseURL: String, database: DatabaseCredentials,
                              timeZone: String) -> [String: String] {
        var form = defaults
        for (k, v) in installerOverrides(baseURL: baseURL, database: database, timeZone: timeZone) { form[k] = v }
        if newFunctions {
            for (k, v) in form where (k.hasPrefix("new_functions_") || k.hasPrefix("new_function_")) && (v == "true" || v == "false") {
                form[k] = "true"
            }
            form["alliance_bonuses"] = "true"
        }
        return form
    }

    private static let key = "TravianZ.world"
    public static func load(from defaults: UserDefaults = .standard) -> WorldSettings {
        guard let d = defaults.data(forKey: key), let s = try? JSONDecoder().decode(WorldSettings.self, from: d) else {
            return WorldSettings()
        }
        return s
    }
    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }
}

public struct DatabaseCredentials: Equatable, Sendable {
    public var user: String
    public var password: String
    public var name: String
    public init(user: String, password: String, name: String) {
        self.user = user; self.password = password; self.name = name
    }
}
