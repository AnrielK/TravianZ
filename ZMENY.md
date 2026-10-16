# Změny

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
