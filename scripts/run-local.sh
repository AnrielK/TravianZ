#!/usr/bin/env bash
# Runs TravianZ on Linux/macOS exactly like the iOS app does: MariaDB on a unix socket (no networking),
# PHP's built-in server with ios/runtime/router.php, the web installer driven headlessly, a 2-second tick.
#
#   scripts/run-local.sh start     # → http://127.0.0.1:8080  (state in .local/)
#   scripts/run-local.sh stop
#   scripts/run-local.sh reset     # stop + delete .local/
#
# TZ_PHP=<php binary>: use that PHP with -n (no php.ini) – e.g. a ZTS build configured like ios/php.
# Needs: php 8.3 (mysqli, mbstring, gd), mariadb (mariadbd + mariadb-install-db), python3, rsync.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L="${TZ_LOCAL_DIR:-$ROOT/.local}"
PORT="${TZ_PORT:-8080}"
SOCK="$L/run/m.sock"
TOKEN_FILE="$L/secrets.json"
mkdir -p "$L"

stop() {
  [[ -f "$L/run/tick.pid" ]] && kill "$(cat "$L/run/tick.pid")" 2>/dev/null || true
  [[ -f "$L/run/php.pid" ]] && kill "$(cat "$L/run/php.pid")" 2>/dev/null || true
  [[ -f "$L/run/mariadbd.pid" ]] && kill "$(cat "$L/run/mariadbd.pid")" 2>/dev/null || true
  sleep 1
}

case "${1:-start}" in
  stop) stop; exit 0 ;;
  reset) stop; rm -rf "$L"; exit 0 ;;
  start) ;;
  *) echo "usage: $0 start|stop|reset"; exit 64 ;;
esac

mkdir -p "$L/run" "$L/logs" "$L/sessions" "$L/tmp"
if [[ ! -f "$TOKEN_FILE" ]]; then
  python3 - "$TOKEN_FILE" <<'PY'
import json, secrets, sys
json.dump({"controlToken": secrets.token_hex(16), "adminPassword": secrets.token_urlsafe(9)}, open(sys.argv[1], "w"))
PY
fi
TOKEN=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["controlToken"])' "$TOKEN_FILE")
ADMIN=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["adminPassword"])' "$TOKEN_FILE")
DB_PASS="travianz-ios-local"

# ---- document root: a writable copy of game/ (the installer writes config.php and renames install/) ----
if [[ ! -d "$L/www" ]]; then
  rsync -a --exclude 'Multi-Instance Server' --exclude tests --exclude '.git*' "$ROOT/game/" "$L/www/"
fi

# ---- MariaDB ----
MDB_BIN="$(dirname "$(command -v mariadbd || echo /usr/sbin/mariadbd)")"
[[ -x "$MDB_BIN/mariadbd" ]] || MDB_BIN=/usr/sbin
if [[ ! -d "$L/mariadb/mysql" ]]; then
  mariadb-install-db --no-defaults --datadir="$L/mariadb" --auth-root-authentication-method=normal \
     --skip-test-db --lower-case-table-names=1 > "$L/logs/install-db.log" 2>&1
  NEW_DB=1
fi
ROOT_USER=(); [[ "$(id -u)" == 0 ]] && ROOT_USER=(--user=root)   # containers run as root
"$MDB_BIN/mariadbd" --no-defaults "${ROOT_USER[@]}" --datadir="$L/mariadb" --socket="$SOCK" --skip-networking \
   --pid-file="$L/run/mariadbd.pid" --log-error="$L/logs/mariadb.log" --tmpdir="$L/tmp" \
   --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci --lower-case-table-names=1 \
   --sql-mode=NO_ENGINE_SUBSTITUTION --innodb-buffer-pool-size=48M --innodb-flush-log-at-trx-commit=2 --skip-name-resolve > /dev/null 2>&1 &
for _ in $(seq 1 120); do mariadb --no-defaults -S "$SOCK" -uroot -e 'SELECT 1' >/dev/null 2>&1 && break; sleep 0.5; done
if [[ "${NEW_DB:-0}" == 1 ]]; then
  mariadb --no-defaults -S "$SOCK" -uroot <<SQL
CREATE DATABASE travianz CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'travianz'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON travianz.* TO 'travianz'@'localhost';
FLUSH PRIVILEGES;
SQL
fi

# ---- PHP ----
export TZ_CONTROL_TOKEN="$TOKEN" TZ_DB_HOST=localhost TZ_DB_USER=travianz TZ_DB_PASSWORD="$DB_PASS" TZ_DB_NAME=travianz
export TMPDIR="$L/tmp"
"${TZ_PHP:-php}" ${TZ_PHP:+-n} -d "mysqli.default_socket=$SOCK" -d "pdo_mysql.default_socket=$SOCK" \
    -d display_errors=0 -d log_errors=1 -d "error_log=$L/logs/php-errors.log" -d error_reporting=E_ALL \
    -d memory_limit=512M -d max_execution_time=0 -d "session.save_path=$L/sessions" \
    -d date.timezone="${TZ_TIMEZONE:-Europe/Prague}" -d opcache.enable=0 -d opcache.enable_cli=0 \
    -S "127.0.0.1:$PORT" -t "$L/www" "$ROOT/ios/runtime/router.php" >> "$L/logs/server.log" 2>&1 &
echo $! > "$L/run/php.pid"
for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$PORT/__tz/health" >/dev/null && break; sleep 0.2; done

# ---- installer ----
if ! curl -sf "http://127.0.0.1:$PORT/__tz/health" | grep -q '"ready"'; then
  cat > "$L/install.json" <<JSON
{"db_user": "travianz", "db_password": "$DB_PASS", "db_name": "travianz", "admin_password": "$ADMIN",
 "speed": ${TZ_SPEED:-10}, "world_max": ${TZ_WORLD_MAX:-50}, "timezone": "${TZ_TIMEZONE:-Europe/Prague}"}
JSON
  python3 "$ROOT/scripts/tz_install.py" "http://127.0.0.1:$PORT" "$L/install.json" 2>&1 | tee "$L/logs/setup.log"
fi

# ---- tick (the iOS app does this every 2 s) ----
( while true; do curl -s -m 300 -H "X-TZ-Token: $TOKEN" "http://127.0.0.1:$PORT/__tz/tick" >> "$L/logs/automation.log"; echo >> "$L/logs/automation.log"; sleep 2; done ) > /dev/null 2>&1 &
echo $! > "$L/run/tick.pid"

echo "TravianZ: http://127.0.0.1:$PORT/   admin: Admin / $ADMIN   (Multihunter, Support: same password)"
echo "control token: $TOKEN"
