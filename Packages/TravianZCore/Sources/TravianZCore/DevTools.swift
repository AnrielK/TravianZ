import Foundation

/// Test shortcuts of the Tools sheet: plain SQL on the TravianZ tables (prefix s1_, see WorldSettings).
/// The automation tick picks the changes up within a second or two.
public enum DevTool: String, CaseIterable, Identifiable, Sendable {
    case finishQueues, fillStorage, gold, silver, noProtection, troops

    public var id: String { rawValue }

    public enum Target: Hashable, Sendable {
        case allPlayers
        case player(Int)
    }

    public var title: String {
        switch self {
        case .finishQueues: "Dokončit fronty hned"
        case .fillStorage: "Naplnit sklady"
        case .gold: "+1000 zlata"
        case .silver: "+10 000 stříbra hrdiny"
        case .noProtection: "Zrušit ochranu začátečníka"
        case .troops: "+100 jednotek prvního typu"
        }
    }

    public var icon: String {
        switch self {
        case .finishQueues: "forward.end.fill"
        case .fillStorage: "shippingbox.fill"
        case .gold: "dollarsign.circle.fill"
        case .silver: "circle.hexagongrid.fill"
        case .noProtection: "shield.slash"
        case .troops: "figure.walk"
        }
    }

    public var help: String? {
        switch self {
        case .finishQueues:
            return "Stavby, bourání, výzkum, výcvik a pohyby vojsk – dokončí je automatizace během pár vteřin"
        case .troops:
            return "Do každé vesnice hráče (Římané u1, Germáni u11, Galové u21, …)"
        default:
            return nil
        }
    }

    /// Real players have ids above 5 (1–5: Support, Nature, Natars, Taskmaster, Multihunter).
    static func users(_ t: Target) -> String {
        switch t {
        case .allPlayers: "id > 5"
        case .player(let id): "id = \(id)"
        }
    }

    static func owners(_ t: Target) -> String {
        switch t {
        case .allPlayers: "owner > 5"
        case .player(let id): "owner = \(id)"
        }
    }

    static func villages(_ t: Target) -> String {
        switch t {
        case .allPlayers: "SELECT wref FROM s1_vdata WHERE owner > 5"
        case .player(let id): "SELECT wref FROM s1_vdata WHERE owner = \(id)"
        }
    }

    public func sql(for target: Target) -> String {
        let v = Self.villages(target)
        switch self {
        case .finishQueues:
            return """
            UPDATE s1_bdata SET timestamp = LEAST(timestamp, UNIX_TIMESTAMP() - 1) WHERE wid IN (\(v));
            UPDATE s1_demolition SET timetofinish = LEAST(timetofinish, UNIX_TIMESTAMP() - 1) WHERE vref IN (\(v));
            UPDATE s1_research SET timestamp = LEAST(timestamp, UNIX_TIMESTAMP() - 1) WHERE vref IN (\(v));
            UPDATE s1_training SET timestamp2 = LEAST(timestamp2, UNIX_TIMESTAMP() - 1), eachtime = 0, timestamp = LEAST(timestamp, UNIX_TIMESTAMP()) WHERE vref IN (\(v));
            UPDATE s1_movement SET endtime = LEAST(endtime, UNIX_TIMESTAMP() - 1) WHERE proc = 0 AND (`from` IN (\(v)) OR `to` IN (\(v)));
            """
        case .fillStorage:
            return "UPDATE s1_vdata SET wood = maxstore, clay = maxstore, iron = maxstore, crop = maxcrop WHERE \(Self.owners(target));"
        case .gold:
            return "UPDATE s1_users SET gold = gold + 1000 WHERE \(Self.users(target));"
        case .silver:
            return "UPDATE s1_hero SET silver = silver + 10000 WHERE uid IN (SELECT id FROM s1_users WHERE \(Self.users(target)));"
        case .noProtection:
            return "UPDATE s1_users SET protect = UNIX_TIMESTAMP() WHERE \(Self.users(target));"
        case .troops:
            // first unit of the tribe: (tribe-1)*10+1  → u1, u11, u21, …, u81
            return (1...9).map { tribe in
                "UPDATE s1_units SET u\((tribe - 1) * 10 + 1) = u\((tribe - 1) * 10 + 1) + 100 WHERE vref IN (SELECT wref FROM s1_vdata WHERE owner IN (SELECT id FROM s1_users WHERE tribe = \(tribe) AND \(Self.users(target))));"
            }.joined(separator: "\n")
        }
    }

    public static let playersQuery = """
        SELECT u.id, u.username,
               CASE u.tribe WHEN 1 THEN 'Římané' WHEN 2 THEN 'Germáni' WHEN 3 THEN 'Galové' WHEN 6 THEN 'Hunové'
                            WHEN 7 THEN 'Egypťané' WHEN 8 THEN 'Sparťané' WHEN 9 THEN 'Vikingové' ELSE u.tribe END,
               u.gold, (SELECT COUNT(*) FROM s1_vdata v WHERE v.owner = u.id),
               (SELECT COALESCE(SUM(v.pop), 0) FROM s1_vdata v WHERE v.owner = u.id), u.access
        FROM s1_users u WHERE u.id > 5 ORDER BY u.id
        """

    public static let snippets: [(title: String, sql: String)] = [
        ("Hráči", "SELECT id, username, tribe, access, gold, protect, FROM_UNIXTIME(timestamp) AS last_seen FROM s1_users ORDER BY id;"),
        ("Vesnice", "SELECT wref, owner, name, pop, ROUND(wood) wood, ROUND(clay) clay, ROUND(iron) iron, ROUND(crop) crop, maxstore, maxcrop FROM s1_vdata WHERE owner > 5;"),
        ("Fronta staveb", "SELECT id, wid, field, type, level, FROM_UNIXTIME(timestamp) AS done_at FROM s1_bdata ORDER BY timestamp;"),
        ("Výcvik", "SELECT id, vref, unit, amt, eachtime, FROM_UNIXTIME(timestamp2) AS next_unit FROM s1_training;"),
        ("Pohyby vojsk", "SELECT moveid, sort_type, `from`, `to`, FROM_UNIXTIME(endtime) AS arrives, proc FROM s1_movement WHERE proc = 0;"),
        ("Hlášení", "SELECT id, uid, topic, FROM_UNIXTIME(time) AS at FROM s1_ndata ORDER BY id DESC LIMIT 50;"),
        ("Hrdinové", "SELECT heroid, uid, name, level, experience, health, silver FROM s1_hero;"),
        ("Velikost tabulek", "SELECT table_name, table_rows, ROUND((data_length + index_length) / 1024) AS kb FROM information_schema.tables WHERE table_schema = DATABASE() ORDER BY kb DESC;"),
    ]
}
