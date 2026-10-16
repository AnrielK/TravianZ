# TravianZ pro iOS (offline)

Swift aplikace, která spustí **TravianZ v11** (PHP 8.3 + MariaDB) **přímo v iPhonu nebo iPadu** – bez Macu,
bez Dockeru a bez internetu – a přidá k tomu nástroje pro testování kódu hry.

- **MariaDB 11.4** přeložená pro iOS jako knihovna (`ios/mariadb/`). Běží ve vlákně aplikace s vlastním
  datovým adresářem, PHP se připojuje unixovým socketem. Herní SQL se nijak nepřekládá.
- **PHP 8.3 (ZTS)** jako knihovna (`ios/php/`). Ve vlákně běží vestavěný web server (`php -S`)
  s routerem `ios/runtime/router.php`, který nahrazuje Apache a `.htaccess` (zákaz `.tpl/.sql/.log`, `var/`,
  index složek, každý skript běží ve své složce jako pod mod_php).
- **Instalace** proběhne při prvním spuštění sama: aplikace projde původní webový instalátor `install/`
  krok za krokem (konfigurace → tabulky → mapa → obilná pole → účty → dokončení), jen s vlastním nastavením.
- **Automatizace** (`cron.php`): aplikace každé 2 s zavolá `/__tz/tick`, který spustí jeden tick `cron.php`
  – stejně jako cron na serveru, jen častěji.
- Kód hry ve složce `game/` je **beze změn** z TravianZ (Shadowss/TravianZ, GPL-3.0).

## Co aplikace umí (v0.1)

Spodní lišta:

| Tlačítko | Co dělá |
|---|---|
| Zpět, Obnovit | navigace ve hře |
| Menu | Pole, Centrum, Mapa, Shromaždiště, Hlášení, Zprávy, Statistiky, Přehled vesnic, Registrace, Přihlášení, Odhlásit, Admin panel |
| **Nástroje** | pro vybraného hráče nebo všechny: dokončit fronty hned, naplnit sklady, +1000 zlata, +10 000 stříbra hrdiny, zrušit ochranu, +100 jednotek; seznam hráčů; vypínač automatizace; ruční tick; **nový svět** |
| **2. hráč** | druhý prohlížeč s vlastními cookies – přihlášení za jiného hráče (útoky, zprávy, aliance) |
| Více | **Logy** (PHP chyby, server, cron, MariaDB, start, přístupy), **SQL konzole** se šablonami, **Nastavení světa** |

Nastavení světa: grafika (Travian Default / Travian T4), jazyk, rychlost hry a vojsk (platí hned),
velikost mapy a zapnutí všech nových funkcí v11 – hrdina T4, Hunové, Egypťané, Sparťané, Vikingové,
bonusy aliancí… (platí pro nový svět).

Účty po instalaci: **Admin** (hráč s přístupem admina), **Multihunter** a **Support** – všechny se stejným
heslem, které je vidět v Nástrojích. Další hráče založíte normální registrací.

## Struktura

```
project.yml                     XcodeGen (projekt se negeneruje do gitu)
TravianZ/                       SwiftUI aplikace
  App/                          @main
  Runtime/                      GameRuntime (vlákna PHP + MariaDB, instalace, tick), GameFiles, Paths
  Browser/                      WKWebView
  Game/                         hlavní obrazovka s lištou
  Tools/  Logs/  Settings/      listy Nástroje, 2. hráč, SQL, Logy, Nastavení
  Resources/Assets.xcassets     ikona + AccentColor
Packages/TravianZCore/          logika bez UI: parser formuláře instalátoru, Installer, nastavení světa,
                                odpovědi /__tz, SQL testovacích nástrojů (swift test)
game/                           TravianZ v11 (beze změn)
ios/runtime/                    router.php (náhrada Apache) + control.php (/__tz/health|status|tick|sql|configure|reset)
ios/php/, ios/mariadb/          překlad PHP a MariaDB pro iOS (xcframework) + šablona datového adresáře
ios/tests/e2e.py                end-to-end test hry přes HTTP
scripts/run-local.sh            totéž co aplikace, na Linuxu/Macu (PHP + MariaDB na socketu)
scripts/tz_install.py           headless instalátor (stejný postup jako Installer.swift)
```

## Jak získat aplikaci

GitHub Actions (`.github/workflows/ios.yml`, push do `main`, pull request nebo ručně):

1. `swift test` balíčku TravianZCore,
2. přeloží PHP a MariaDB pro iOS (poprvé ~40 min, pak z cache),
3. vytvoří šablonu datového adresáře (Homebrew `mariadb@11.4`),
4. přeloží aplikaci, **spustí ji v simulátoru, nechá proběhnout instalaci a projde hru end-to-end**,
5. vyrobí **nepodepsanou IPA** – artefakt `TravianZ-unsigned-ipa`.

IPA nainstalujete přes Sideloadly / AltStore, nebo projekt otevřete v Xcode
(`xcodegen generate && open TravianZ.xcodeproj`, knihovny `PHPCore.xcframework` a `mariadb-*` stáhněte
z artefaktů CI do `ios/php/build/` a `ios/mariadb/build/`, pak `ios/mariadb/make-xcframework.sh`
a `ios/mariadb/make-template.sh ios/mariadb/build/template travianz-ios-local`).

Rychlá kontrola samotné hry běží v `.github/workflows/ci.yml` na Linuxu (PHP 8.3 + MariaDB, ~3 min).

Logy z CI se zapisují i do větve `ci-logs` (`.github/scripts/push-ci-logs.sh`).

## Stejný režim na Linuxu/Macu

```bash
scripts/run-local.sh start        # http://127.0.0.1:8080, stav v .local/
python3 ios/tests/e2e.py http://127.0.0.1:8080 <controlToken> <adminPassword>   # oboje v .local/secrets.json
scripts/run-local.sh stop | reset
```

Proměnné: `TZ_PORT`, `TZ_SPEED`, `TZ_WORLD_MAX`, `TZ_TIMEZONE`.

## Omezení

- PHP server je jednovláknový: stránky, obrázky a tick se obsluhují po jedné (pro jednoho testera stačí).
- Když je aplikace na pozadí, iOS ji uspí – automatizace stojí; po návratu dožene vše jedním tickem.
- E-maily se neposílají (aktivace účtů je vypnutá), PayPal a odkazy ven otevírá Safari.
- Instalátor TravianZ při vykreslení patičky hlásí do logu `Undefined constant "TZ_SERVER_RUNNING_ON"`
  (chyba v originálu, instalaci neovlivní).

## Když aplikace spadne při startu

Logy jsou v aplikaci Soubory → Na iPhonu → TravianZ → `logs` (`mariadb.log`, `setup.log`, `php-errors.log`,
`last-start.txt` s krokem, ve kterém start skončil). Při dalším spuštění je aplikace ukáže sama.

## Plán

- Volba kmene a jména admin účtu, víc nastavení instalátoru přímo v aplikaci (ochrana začátečníků, Natarové, WW).
- Záloha a obnova světa (export databáze do Souborů).
- Přepínání mezi více světy.
- Rychlé „přetočení času“ (posunout všechny časy o X hodin).
- macOS verze (Mac Catalyst).
