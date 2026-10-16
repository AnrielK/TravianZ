#!/usr/bin/env bash
# Creates the MariaDB data directory bundled into the iOS app (system tables + an empty `travianz` database).
# Runs on the Mac/CI host with Homebrew MariaDB of the SAME major.minor as the compiled iOS server.
#
#   ios/mariadb/make-template.sh <output-dir> <db-password>
#
# lower_case_table_names=1: the template is made on a case-insensitive Mac file system but runs on the
# case-sensitive iPhone one – with 1 table names behave identically on both (the app passes it too).
# The app copies this directory on first launch; the TravianZ web installer creates the tables and the world
# on the device, so the template stays generic.
set -euo pipefail

OUT="${1:?output dir}"
mkdir -p "$OUT" && OUT="$(cd "$OUT" && pwd)"          # mariadbd needs absolute paths
PASSWORD="${2:?database password}"
FORMULA="${MARIADB_FORMULA:-mariadb@11.4}"
PREFIX="$(brew --prefix "$FORMULA")"
BIN="$PREFIX/bin"
SOCK="/tmp/tz-template-$$.sock"
DATA="$OUT/data"

rm -rf "$DATA" "$OUT"/*.log "$OUT"/*.err; mkdir -p "$DATA"
"$BIN/mariadb-install-db" --no-defaults --basedir="$PREFIX" --datadir="$DATA" \
    --auth-root-authentication-method=normal --skip-test-db --lower-case-table-names=1 >"$OUT/install.log" 2>&1 \
    || { head -n 40 "$OUT/install.log"; exit 1; }

"$BIN/mariadbd" --no-defaults --datadir="$DATA" --socket="$SOCK" --skip-networking \
    --pid-file="$OUT/template.pid" --log-error="$OUT/template.err" \
    --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci --lower-case-table-names=1 &
for _ in $(seq 1 120); do "$BIN/mariadb" --no-defaults -S "$SOCK" -uroot -e 'SELECT 1' >/dev/null 2>&1 && break; sleep 0.5; done

sql() { "$BIN/mariadb" --no-defaults -S "$SOCK" -uroot "$@"; }
sql <<SQL
CREATE DATABASE travianz CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'travianz'@'localhost' IDENTIFIED BY '$PASSWORD';
GRANT ALL PRIVILEGES ON travianz.* TO 'travianz'@'localhost';
FLUSH PRIVILEGES;
SQL
sql -N -e "SELECT VERSION()" > "$OUT/version.txt"

"$BIN/mariadb-admin" --no-defaults -S "$SOCK" -uroot shutdown
wait || true
rm -f "$DATA"/*.err "$DATA"/*.pid "$DATA"/aria_log_control.lock
du -sh "$DATA"
echo "Template ready: $DATA ($(cat "$OUT/version.txt"))"
