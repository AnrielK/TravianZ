#!/usr/bin/env python3
"""End-to-end gameplay test of TravianZ over HTTP (Python standard library only).

Runs against the iOS app in the simulator or against scripts/run-local.sh:

    python3 ios/tests/e2e.py http://127.0.0.1:8080 <control-token> <admin-password>

The control token (X-TZ-Token) unlocks /__tz/sql and /__tz/tick, used to fast-forward the build queue and to
read the database. Exit code 0 = everything passed (last line "E2E PASSED").
"""
import html
import http.cookiejar
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080").rstrip("/")
TOKEN = sys.argv[2] if len(sys.argv) > 2 else ""
ADMIN_PW = sys.argv[3] if len(sys.argv) > 3 else ""
PROBLEMS = re.compile(r"Fatal error|Uncaught (Error|Exception)|Parse error|<b>Warning</b>:|<b>Notice</b>:|"
                      r"<b>Deprecated</b>:|mysqli_sql_exception", re.I)
failures = []
step_no = 0


def step(title):
    global step_no
    step_no += 1
    print(f"[{step_no:02d}] {title}", flush=True)


def fail(msg):
    print("   FAIL: " + msg, flush=True)
    failures.append(msg)


def text_of(page):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", page))).strip()


class Client:
    def __init__(self, name):
        self.name = name
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))

    def req(self, path, data=None, headers=None, timeout=300):
        url = path if path.startswith("http") else BASE + "/" + path.lstrip("/")
        body = urllib.parse.urlencode(data).encode() if isinstance(data, dict) else data
        r = urllib.request.Request(url, data=body, headers=headers or {})
        try:
            resp = self.opener.open(r, timeout=timeout)
            return resp.status, resp.geturl(), resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, url, e.read().decode("utf-8", "replace")

    def page(self, path, data=None, expect=200, check=True):
        code, url, text = self.req(path, data)
        if code != expect:
            fail(f"{self.name}: {path} -> HTTP {code} (expected {expect}) {text_of(text)[:200]!r}")
        elif check:
            m = PROBLEMS.search(text)
            if m:
                fail(f"{self.name}: {path} contains {m.group(0)!r}: {text_of(text[m.start():m.start() + 600])[:300]!r}")
        return code, url, text


def control(action, data=None):
    code, _, text = Client("control").req(f"/__tz/{action}", data, headers={"X-TZ-Token": TOKEN})
    try:
        return json.loads(text)
    except ValueError:
        fail(f"control {action}: HTTP {code} {text[:300]!r}")
        return {}


def sql(query):
    r = control("sql", {"query": query})
    if r.get("error"):
        fail(f"sql {query[:60]!r}: {r['error']}")
    sets = r.get("sets") or []
    return sets[-1]["rows"] if sets else []


def scalar(query):
    rows = sql(query)
    return rows[0][0] if rows and rows[0] else None


def tick(n=1):
    for _ in range(n):
        r = control("tick")
        if not r.get("ok"):
            fail(f"tick: {r}")


def register(c, name, pw, tribe):
    c.page("anmelden.php")
    data = {"invited": "", "ft": "a1", "vid": str(tribe), "kid": "0", "name": name,
            "email": f"{name.lower()}@example.com", "pw": pw, "agb": "1", "s1": "anmelden"}
    code, url, text = c.page("anmelden.php", data)
    uid = scalar(f"SELECT id FROM s1_users WHERE username = '{name}'")
    if not uid:
        fail(f"registration of {name} did not create a user (ended at {url}): {text_of(text)[:300]!r}")
    return uid


def login(c, name, pw):
    code, url, text = c.page("login.php", {"ft": "a4", "user": name, "pw": pw, "s1": "login"})
    if "dorf1.php" not in url and "logout.php" not in text:
        fail(f"login {name}: ended at {url}: {text_of(text)[:300]!r}")
    return text


def main():
    step("server ready")
    for _ in range(120):
        try:
            if json.loads(Client("h").req("/__tz/health", timeout=10)[2]).get("status") == "ready":
                break
        except Exception:
            pass
        time.sleep(2)
    else:
        fail("server never became ready")
        return
    st = control("status")
    print("   ", json.dumps({k: st.get(k) for k in ("installed", "db", "users", "villages", "tiles", "settings")}))
    if not st.get("installed"):
        fail("not installed")
        return

    step("landing pages (logged out)")
    guest = Client("guest")
    for p in ["index.php", "anmelden.php", "login.php", "spielregeln.php", "anleitung.php", "impressum.php",
              "agb.php", "statistiken.php", "warsim.php", "manual.php"]:
        guest.page(p)
    _, _, login_page = guest.page("login.php")
    if "Server will start in" in login_page:
        fail("the world has not started yet (START_DATE/START_TIME in the future)")
    guest.page("var/installed", expect=403, check=False)
    guest.page("GameEngine/config.php", check=False)          # executes, prints nothing
    code, _, body = guest.req("GameEngine/config.php")
    if "SQL_PASS" in body:
        fail("config.php source is readable")
    guest.page("Templates/footer.tpl", expect=403, check=False)

    step("register two players")
    p1, p2 = Client("Alpha"), Client("Bravo")
    stamp = str(int(time.time()))[-5:]
    n1, n2 = "Alpha" + stamp, "Bravo" + stamp
    uid1 = register(p1, n1, "secret123", 3)
    uid2 = register(p2, n2, "secret123", 2)
    print(f"    uids {uid1}, {uid2}")

    step("log in")
    login(p1, n1, "secret123")
    login(p2, n2, "secret123")
    wref1 = scalar(f"SELECT wref FROM s1_vdata WHERE owner = {uid1 or 0} LIMIT 1")
    wref2 = scalar(f"SELECT wref FROM s1_vdata WHERE owner = {uid2 or 0} LIMIT 1")
    if not wref1 or not wref2:
        fail("players have no village")
        return

    step("game pages")
    pages = ["dorf1.php", "dorf2.php", "dorf3.php", "karte.php", "karte.php?z=" + str(wref2), "karte2.php",
             "statistiken.php", "statistiken.php?id=2", "statistiken.php?id=4", "berichte.php", "nachrichten.php",
             "nachrichten.php?t=1", "spieler.php?uid=" + str(uid1), "spieler.php?s=1", "allianz.php", "plus.php",
             "plus.php?id=3", "build.php?id=1", "build.php?id=19", "build.php?id=26", "build.php?id=39",
             "build.php?id=40", "warsim.php", "crop_finder.php", "manual.php?typ=4&gid=1", "celebration.php",
             "support.php", "tutorial.php", "rules.php"]
    for p in pages:
        p1.page(p)
    for p in ["dorf1.php", "dorf2.php", "karte.php", "build.php?id=39"]:
        p2.page(p)

    step("upgrade a resource field and finish it via the automation tick")
    sql(f"UPDATE s1_vdata SET wood = 5000, clay = 5000, iron = 5000, crop = 5000, maxstore = 8000, maxcrop = 8000 "
        f"WHERE wref = {wref1}")
    before = int(scalar(f"SELECT f1 FROM s1_fdata WHERE vref = {wref1}") or 0)
    _, _, page = p1.page("build.php?id=1")
    link = re.search(r'href="(dorf[12]\.php\?a=1&(?:amp;)?c=[^"]+)"', page)
    if not link:
        fail("no upgrade link on build.php?id=1: " + text_of(page)[:400])
    else:
        p1.page(html.unescape(link.group(1)))
        queued = scalar(f"SELECT COUNT(*) FROM s1_bdata WHERE wid = {wref1}")
        if queued in (None, "0"):
            fail("upgrade not queued")
        sql(f"UPDATE s1_bdata SET timestamp = UNIX_TIMESTAMP() - 1 WHERE wid = {wref1}")
        tick(2)
        after = int(scalar(f"SELECT f1 FROM s1_fdata WHERE vref = {wref1}") or 0)
        left = scalar(f"SELECT COUNT(*) FROM s1_bdata WHERE wid = {wref1}")
        print(f"    field 1: level {before} -> {after}, queue {left}")
        if after != before + 1:
            fail(f"field 1 level {before} -> {after} after the tick")
    p1.page("dorf1.php")

    step("quest 3: rename the village (iOS keyboard apostrophe)")
    sql(f"UPDATE s1_users SET quest = 3 WHERE id = {uid2}")
    p2.page("dorf1.php")
    p2.page("spieler.php?s=1")
    code, url, resp = p2.req("spieler.php", {"ft": "p1", "mw": "0", "tag": "", "monat": "", "jahr": "", "ort": "e2e-ort", "be1": "", "be2": "",
                            "dname0": "Bravo\u2019s Hrad!", "s1": "ok"})
    print(f"    POST spieler.php -> {code} {url}")
    vname = scalar(f"SELECT name FROM s1_vdata WHERE wref = {wref2}")
    _, _, q = p2.req("ajax.php?f=qst")
    num = re.search(r'"number":"?(-?\d+)', q)
    print(f"    village name {vname!r}, quest {num and num.group(1)}")
    if vname != "Bravos Hrad":
        mode = sql(f"SELECT @@GLOBAL.sql_mode, @@version, (SELECT location FROM s1_users WHERE id = {uid2})")
        fail(f"village rename not saved: {vname!r}; sql_mode/version {mode}; response {text_of(resp)[:300]!r}")
    if not num or num.group(1) != "3":
        fail(f"quest 3 not completed after the rename: {q[:200]!r}")

    step("message between players")
    p1.page("nachrichten.php?t=1")
    p1.page("nachrichten.php", {"an": n2, "be": "Hello", "message": "Test message from e2e", "ft": "m2",
                                "c": "", "s1": "send"})
    got = scalar(f"SELECT COUNT(*) FROM s1_mdata WHERE target = {uid2} AND topic LIKE 'Hello%'")
    if got in (None, "0"):
        fail("message not delivered")
    _, _, inbox = p2.page("nachrichten.php")
    if "Hello" not in inbox:
        fail("message not in the inbox")

    step("send troops (raid) and let them arrive")
    sql(f"UPDATE s1_fdata SET f39 = 1, f39t = 16 WHERE vref = {wref1}")     # rally point
    sql(f"UPDATE s1_units SET u21 = 20 WHERE vref = {wref1}")               # Gauls: 20 Phalanx
    sql(f"UPDATE s1_users SET protect = 0 WHERE id IN ({uid1}, {uid2})")
    x2, y2 = sql(f"SELECT x, y FROM s1_wdata WHERE id = {wref2}")[0]
    p1.page("build.php?id=39")
    p1.page(f"a2b.php?z={wref2}")
    form = {"b": "1", "t1": "10", "c": "4", "dname": "", "x": x2, "y": y2, "s1": "ok"}
    _, url, confirm = p1.page("a2b.php", form)
    conf = {}
    for m in re.finditer(r"<input([^>]*)>", confirm):
        attrs = dict(re.findall(r'(\w+)="([^"]*)"', m.group(1)))
        if attrs.get("name") and attrs.get("type", "text") in ("hidden", "text"):
            conf[attrs["name"]] = html.unescape(attrs.get("value", ""))
    if conf.get("a") != "533374":
        fail(f"no confirmation form (ended at {url}): " + text_of(confirm)[:300])
    else:
        conf["s1"] = "ok"
        p1.page("a2b.php", conf)
    moving = scalar(f"SELECT COUNT(*) FROM s1_movement WHERE `from` = {wref1} AND proc = 0")
    print(f"    movements: {moving}")
    if moving in (None, "0"):
        fail("raid not sent")
    else:
        sql(f"UPDATE s1_movement SET endtime = UNIX_TIMESTAMP() - 1 WHERE `from` = {wref1} AND proc = 0")
        tick(2)
        reports = scalar(f"SELECT COUNT(*) FROM s1_ndata WHERE uid = {uid1}")
        print(f"    reports for attacker: {reports}")
        if reports in (None, "0"):
            fail("no battle report after the raid arrived")
        p1.page("berichte.php")
        p2.page("berichte.php")
        rid = scalar(f"SELECT id FROM s1_ndata WHERE uid = {uid1} ORDER BY id DESC LIMIT 1")
        if rid:
            p1.page(f"berichte.php?id={rid}")

    step("admin panel")
    admin = Client("Admin")
    login(admin, "Admin", ADMIN_PW)
    admin.page("Admin/admin.php")
    admin.page("Admin/admin.php?p=server_info", check=False)

    step("automation tick is healthy")
    t = time.time()
    tick(3)
    print(f"    3 ticks in {time.time() - t:.2f} s")

    step("log out")
    p1.page("logout.php")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:                 # report, do not hide the traceback
        import traceback
        traceback.print_exc()
        fail(f"exception: {e}")
    print()
    if failures:
        print(f"E2E FAILED ({len(failures)} problems)")
        for f in failures:
            print(" - " + f[:500])
        sys.exit(1)
    print("E2E PASSED")
