#!/usr/bin/env python3
"""Runs the TravianZ web installer (install/) headlessly over HTTP – the same steps a person clicks through.

    python3 scripts/tz_install.py <base-url> <settings.json>

settings.json (all optional except db_*):
    {"db_user": "...", "db_password": "...", "db_name": "...", "admin_password": "...",
     "speed": 10, "world_max": 50, "timezone": "Europe/Prague", "gp_locate": "gpack/travian_default/",
     "new_functions": true, "server_name": "TravianZ"}

The form defaults are read from the installer page itself (input values, selected options), then overridden.
The Swift app does the same in TravianZCore/Installer.swift – keep both in sync.
Exit code 0 = installed.
"""
import http.cookiejar
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser


class FormDefaults(HTMLParser):
    """Collects name → default value of every input/select inside the first <form>."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.values = {}
        self.select = None
        self.select_first = None
        self.select_chosen = None
        self.in_form = False
        self.done = False

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if self.done:
            return
        if tag == "form":
            self.in_form = True
        if not self.in_form:
            return
        if tag == "input" and a.get("name") and a.get("type", "text") not in ("submit", "button", "checkbox", "radio") \
                and "disabled" not in a:
            self.values[a["name"]] = a.get("value", "")
        elif tag == "select" and a.get("name"):
            self.select, self.select_first, self.select_chosen = a["name"], None, None
        elif tag == "option" and self.select:
            v = a.get("value", "")
            if self.select_first is None and "disabled" not in a:
                self.select_first = v
            if "selected" in a and self.select_chosen is None:
                self.select_chosen = v

    def handle_endtag(self, tag):
        if tag == "select" and self.select:
            self.values[self.select] = self.select_chosen if self.select_chosen is not None else (self.select_first or "")
            self.select = None
        elif tag == "form" and self.in_form:
            self.in_form, self.done = False, True


def overrides(s, base):
    o = {
        "servername": s.get("server_name", "TravianZ"),
        "tzone": "0," + s.get("timezone", "Europe/Prague"),
        "speed": str(s.get("speed", 10)),
        "incspeed": str(s.get("troop_speed", 1)),
        "wmax": str(s.get("world_max", 50)),
        "lang": s.get("lang", "en"),
        "sserver": "localhost", "sport": "3306",
        "suser": s["db_user"], "spass": s["db_password"], "sdb": s["db_name"], "prefix": "s1_",
        "server": base + "/", "domain": base + "/", "homepage": base + "/",
        "cron_loop": "0", "cron_tick": "15",
        "gp_locate": s.get("gp_locate", "gpack/travian_default/"),
        "gpack": "true",
    }
    return o


def run(base, s, log=print):
    base = base.rstrip("/")
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

    def req(path, data=None, timeout=1800):
        body = urllib.parse.urlencode(data).encode() if data is not None else None
        try:
            r = opener.open(urllib.request.Request(base + path, data=body), timeout=timeout)
            return r.status, r.geturl(), r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, base + path, e.read().decode("utf-8", "replace")

    def expect(url, fragment, what, text):
        if fragment not in url:
            raise SystemExit(f"installer step '{what}' failed: ended at {url}\n{re.sub(r'<[^>]+>', ' ', text)[:800]}")

    log("install 1/6: config form")
    code, url, text = req("/install/index.php?s=1")
    if "Installation appears to have been completed" in text:
        log("already installed")
        return True
    p = FormDefaults()
    p.feed(text)
    form = dict(p.values)
    if "subconst" not in form:
        raise SystemExit("config form not found:\n" + text[:800])
    form.update(overrides(s, base))
    if s.get("new_functions", True):
        for k in list(form):
            if k.startswith(("new_functions_", "new_function_")) and form[k] in ("true", "false"):
                form[k] = "true"
        form["alliance_bonuses"] = "true"
    code, url, text = req("/install/process.php", form)
    expect(url, "s=2", "config", text)

    log("install 2/6: database structure")
    code, url, text = req("/install/process.php", {"substruc": "1"})
    expect(url, "s=3", "structure", text)

    log("install 3/6: world data")
    t = time.time()
    code, url, text = req("/install/process.php", {"subwdata": "1"})
    expect(url, "startCroppers=1", "world data", text)
    log(f"   {time.time() - t:.1f} s")

    log("install 4/6: croppers")
    code, url, text = req("/install/ajax_croppers.php")
    events = [json.loads(line[6:]) for line in text.splitlines() if line.startswith("data: {")]
    if not events or events[-1].get("error") or events[-1].get("pct", 0) < 100:
        raise SystemExit(f"croppers failed: {events[-1:] or text[:400]}")

    log("install 5/6: accounts")
    pw = s["admin_password"]
    code, url, text = req("/install/include/accounts.php", {
        "mhpw": pw, "spw": pw, "aname": s.get("admin_name", "Admin"), "aemail": "admin@localhost",
        "apass": pw, "atribe": str(s.get("admin_tribe", 1)), "admin_rank": "false",
        "admin_support_msgs": "true", "admin_raidable": "false"})
    expect(url, "s=5", "accounts", text)

    log("install 6/6: finish")
    if "Installation Complete" not in text:          # the redirect after accounts normally ran this step already
        code, url, text = req("/install/index.php?s=5")
    if "Installation Complete" not in text:
        raise SystemExit("finish step failed:\n" + re.sub(r"<[^>]+>", " ", text)[:600])
    return True


if __name__ == "__main__":
    settings = json.load(open(sys.argv[2]))
    run(sys.argv[1], settings)
    print("INSTALLED")
