# Změny

## 0.1.3 – 16. 10. 2026

- Skutečná příčina chyby s úkolem 3: PCRE v PHP pro iOS (arm64) nenajde shodu u třídy znaků s Unicode
  vlastnostmi, např. `[\p{L}\p{N}._-]` – na Linuxu se stejnou verzí PHP i PCRE funguje. Kontrola názvu vesnice
  v `Profile.php` proto na iPhonu odmítla každý název. Vzory jsou přepsané na alternaci
  `(?:\p{L}|\p{N}|[._\-\[\]()])` se stejným významem; jinde ve hře se tato konstrukce nepoužívá.
- `/__tz/selftest`: kontrola řetězcových funkcí PHP v aplikaci (vypíše ji e2e test, když selže přejmenování).
- MariaDB v aplikaci běží s `sql_mode=NO_ENGINE_SUBSTITUTION` (nestriktní, jako Docker se `sql_mode=""`).

## 0.1.2 – 16. 10. 2026

- Oprava hry (`game/GameEngine/Profile.php`): název vesnice s apostrofem, čárkou, vykřičníkem, `#` apod. se tiše
  neuložil – úkol 3 (přejmenovat vesnici) nešel splnit. Na iPhonu stačil apostrof, který klávesnice píše jako `’`,
  nebo úprava výchozího názvu „…'s village“. Apostrofy se teď odstraní, ostatní nepovolené znaky nahradí mezerou
  a název se uloží (ochrana proti XSS zůstává).
- e2e test: úkol 3 s názvem z iOS klávesnice.

## 0.1.1 – 16. 10. 2026

- Oprava: nový svět ukazoval „Server will start in“ asi hodinu. Instalátor TravianZ předvyplní čas startu
  v časovém pásmu Bukurešti, svět ale běží v pásmu zařízení. Aplikace teď posílá start = teď (pásmo zařízení)
  a při každém spuštění posune start světa, který leží v budoucnu, na teď (`/__tz/startnow`).
- e2e test hlídá, že přihlašovací stránka neukazuje odpočet startu.

## 0.1.0 – 16. 10. 2026

- První verze: TravianZ v11 (PHP 8.3 + MariaDB 11.4) běží offline v iOS aplikaci.
- Router pro vestavěný PHP server místo Apache a `.htaccess`, řídicí endpoint `/__tz` (health, status, tick,
  sql, configure, reset).
- Automatická instalace přes původní webový instalátor (konfigurace, tabulky, mapa, obilná pole, účty).
- Automatizace `cron.php` každé 2 s.
- Nástroje: dokončit fronty, naplnit sklady, zlato, stříbro hrdiny, zrušit ochranu, jednotky, nový svět.
- Druhý hráč (oddělené cookies), logy, SQL konzole, nastavení světa (grafika, jazyk, rychlost, mapa, nové funkce).
- `scripts/run-local.sh` + `ios/tests/e2e.py`: stejný běh na Linuxu/Macu a end-to-end test
  (registrace, přihlášení, ~30 stránek, stavba dokončená automatizací, zpráva, nájezd s hlášením, admin).
- CI: testy jádra, překlad PHP/MariaDB, test v simulátoru, nepodepsaná IPA; rychlý e2e test na Linuxu.
