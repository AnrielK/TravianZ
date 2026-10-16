import XCTest
@testable import TravianZCore

final class InstallFormTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// The installer page captured from a real TravianZ server; the expected values were produced by the Python
    /// parser in scripts/tz_install.py, so both parsers must agree.
    func testDefaultsMatchPythonParser() throws {
        let html = String(decoding: try fixture("install-config.html"), as: UTF8.self)
        let expected = try JSONDecoder().decode([String: String].self, from: try fixture("install-config-defaults.json"))
        var parsed = InstallForm.defaults(in: html)
        XCTAssertNotNil(parsed["prefix"])
        XCTAssertNotNil(parsed["start_date"])
        parsed["prefix"] = "<random>"
        parsed["start_date"] = "<date>"
        parsed["start_time"] = "<time>"
        XCTAssertEqual(parsed.count, expected.count)
        for (k, v) in expected {
            XCTAssertEqual(parsed[k], v, "field \(k)")
        }
    }

    func testKnownDefaults() throws {
        let html = String(decoding: try fixture("install-config.html"), as: UTF8.self)
        let d = InstallForm.defaults(in: html)
        XCTAssertEqual(d["subconst"], "1")
        XCTAssertEqual(d["wmax"], "100")
        XCTAssertEqual(d["lang"], "en")
        XCTAssertEqual(d["medalinterval"], "(3600*24*7)")
        XCTAssertEqual(d["new_functions_hero_t4"], "false")
        XCTAssertEqual(d["gp_locate"], "gpack/travian_default/")
    }

    func testSelectRules() {
        let html = """
        <p><input name="outside" value="x"></p>
        <form><input name="a" value="1"><input name="b" type="checkbox" value="on"><input name="c" disabled value="2">
        <input name='d' value='q&amp;r'><input type="submit" name="go" value="Go">
        <select name="s1"><option value="x" disabled>X</option><option value="y">Y</option><option value="z">Z</option></select>
        <select name="s2"><option value="x">X</option><option value="y" selected>Y</option></select>
        <select name="s3"></select></form><form><input name="later" value="no"></form>
        """
        XCTAssertEqual(InstallForm.defaults(in: html), ["a": "1", "d": "q&r", "s1": "y", "s2": "y", "s3": ""])
    }

    func testEntities() {
        XCTAssertEqual(InstallForm.decodeEntities("a&amp;b &quot;c&quot; &#39;d&#39; &#x41;&#66;"), "a&b \"c\" 'd' AB")
    }
}

final class WorldSettingsTests: XCTestCase {
    let db = DatabaseCredentials(user: "travianz", password: "pw", name: "travianz")

    func testInstallerForm() {
        var s = WorldSettings()
        s.speed = 25
        s.worldMax = 25
        let form = s.installerForm(defaults: ["speed": "1", "new_functions_oasis": "false", "new_function_tribe_huns": "false",
                                              "alliance_bonuses": "false", "box1": "false"],
                                   baseURL: "http://127.0.0.1:8080", database: db, timeZone: "Europe/Prague")
        XCTAssertEqual(form["speed"], "25")
        XCTAssertEqual(form["wmax"], "25")
        XCTAssertEqual(form["tzone"], "0,Europe/Prague")
        XCTAssertEqual(form["homepage"], "http://127.0.0.1:8080/")
        XCTAssertEqual(form["prefix"], "s1_")
        XCTAssertEqual(form["new_functions_oasis"], "true")
        XCTAssertEqual(form["new_function_tribe_huns"], "true")
        XCTAssertEqual(form["alliance_bonuses"], "true")
        XCTAssertEqual(form["box1"], "false")
        XCTAssertEqual(form["cron_loop"], "0")

        s.newFunctions = false
        let plain = s.installerForm(defaults: ["new_functions_oasis": "false"], baseURL: "http://x/", database: db, timeZone: "UTC")
        XCTAssertEqual(plain["new_functions_oasis"], "false")
    }

    func testLiveDefines() {
        var s = WorldSettings()
        s.graphicPack = "gpack/travian_t4/"
        let d = s.liveDefines(baseURL: "http://127.0.0.1:9000")
        XCTAssertEqual(d["HOMEPAGE"], "http://127.0.0.1:9000/")
        XCTAssertEqual(d["SERVER_GP"], "gpack/travian_t4/")
        XCTAssertNil(d["WORLD_MAX"])
        XCTAssertEqual(WorldSettings().tiles, 101 * 101)
    }

    func testCodableRoundTrip() throws {
        var s = WorldSettings()
        s.language = "ro"
        let back = try JSONDecoder().decode(WorldSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testFormEncoding() {
        XCTAssertEqual(FormEncoding.encode(["b": "a b&c", "a": "(3600*24)"]), "a=%283600%2A24%29&b=a%20b%26c")
    }
}

final class ControlModelTests: XCTestCase {
    /// Responses captured from control.php.
    func testDecodeStatus() throws {
        let json = """
        {"ok":true,"installed":true,"config":true,"installer":false,"php":"8.3.6","settings":{"SPEED":"10","WORLD_MAX":"50",
        "SERVER_GP":"gpack/travian_default/","HOMEPAGE":"http://127.0.0.1:8080/","TB_PREFIX":"s1_","SERVER_LANG":"en",
        "TIMEZONE":"Europe/Prague","COMMENCE":null},"db":{"ok":true,"version":"10.11.14-MariaDB","tables":82},
        "users":1,"villages":3,"tiles":10201}
        """
        let s = try JSONDecoder().decode(ServerStatus.self, from: Data(json.utf8))
        XCTAssertTrue(s.installed)
        XCTAssertEqual(s.setting("SPEED"), "10")
        XCTAssertNil(s.setting("COMMENCE"))
        XCTAssertEqual(s.db?.tables, 82)
        XCTAssertEqual(s.tiles, 10201)
    }

    func testDecodeTickAndSQL() throws {
        let tick = try JSONDecoder().decode(TickResult.self, from: Data(#"{"ok":true,"ran":true,"ms":14}"#.utf8))
        XCTAssertEqual(tick.ms, 14)
        let sql = try JSONDecoder().decode(SQLResponse.self, from: Data("""
        {"ok":true,"sets":[{"columns":["MIN(x)","COUNT(*)"],"rows":[["-25","2601"]]}],"affected":0,"ms":1}
        """.utf8))
        XCTAssertEqual(sql.lastSet?.rows.first?.last, "2601")
        let failed = try JSONDecoder().decode(SQLResponse.self, from: Data(#"{"ok":true,"sets":[],"affected":0,"error":"Table 'x' doesn't exist","ms":0}"#.utf8))
        XCTAssertNotNil(failed.error)
    }

    func testServerSentEvents() {
        let body = "data: {\"pct\":0,\"done\":0,\"total\":10}\n\n:\n\ndata: {\"pct\":100,\"done\":10,\"total\":10,\"msg\":\"Done\"}\n\n"
        XCTAssertEqual(Installer.lastEvent(ofStream: body)?["pct"] as? Int, 100)
        XCTAssertNil(Installer.lastEvent(ofStream: "nothing"))
    }
}

final class DevToolTests: XCTestCase {
    func testTargets() {
        XCTAssertTrue(DevTool.gold.sql(for: .allPlayers).contains("id > 5"))
        XCTAssertTrue(DevTool.gold.sql(for: .player(7)).contains("id = 7"))
        XCTAssertTrue(DevTool.fillStorage.sql(for: .player(7)).contains("owner = 7"))
        XCTAssertTrue(DevTool.finishQueues.sql(for: .allPlayers).contains("s1_movement"))
        XCTAssertEqual(DevTool.troops.sql(for: .allPlayers).split(separator: "\n").count, 9)
        XCTAssertTrue(DevTool.troops.sql(for: .allPlayers).contains("u81 = u81 + 100"))
        for tool in DevTool.allCases {
            XCTAssertFalse(tool.sql(for: .allPlayers).contains("\\("), "uninterpolated SQL in \(tool)")
        }
    }
}
