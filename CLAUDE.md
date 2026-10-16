# TravianZ pro iOS – konvence projektu

- Komunikace, UI aplikace, README a ZMENY.md česky. Kód a komentáře v kódu anglicky.
- `game/` je TravianZ (Shadowss/TravianZ) **beze změn**. Opravy hry dělej jen když jsou nutné pro běh v aplikaci,
  vždy malé a popsané v ZMENY.md (ideálně poslat i upstream).
- iOS 17+, SwiftUI, `@Observable` (GameRuntime), `SWIFT_VERSION 5.0`. BrowserModel zůstává ObservableObject.
- Logika bez UI patří do `Packages/TravianZCore` a musí jít otestovat přes `swift test`.
- Bundle ID `com.anriel.travianz`. Projekt generuje XcodeGen (`project.yml`), `.xcodeproj` není v gitu.
- Tabulky mají pevný prefix `s1_` (nastavuje ho Installer). Hráči mají id > 5 (1–5 jsou systémové účty).
- Instalátor má dvě implementace se stejným postupem: `Packages/TravianZCore/.../Installer.swift`
  a `scripts/tz_install.py`. Test `InstallFormTests` porovnává oba parsery na zachycené stránce
  (`Fixtures/install-config.html`). Když se změní instalátor TravianZ, obnov fixture:
  `scripts/run-local.sh start`, `POST /__tz/reset`, `curl /install/index.php?s=1`, výstup parseru z Pythonu do JSON.
- Před pushem: `scripts/run-local.sh start` + `python3 ios/tests/e2e.py …` musí projít (E2E PASSED).
- PHP v aplikaci nemá OPcache ani `pcntl`; každý request je čerstvý (žádný stav mezi requesty kromě souborů a DB).
- Swift typické chyby: `.gray` místo `Color.gray` v ternárních `ShapeStyle`, velké ViewBuildery rozdělit,
  `= nil` u optional vlastností v `@Observable`.
- Logy z CI jsou ve větvi `ci-logs` (`tz-run-<číslo>-<job>/`).
