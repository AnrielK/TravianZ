<?php
/*
 * Local control endpoint of the iOS app:  /__tz/<action>   (executed by router.php in GLOBAL scope)
 *
 *   health     public  {"status":"ready"|"install"}               – used by CI to wait for the app
 *   status     token   install state, DB state, basic counts, key config values
 *   tick       token   one automation tick = cron.php in HTTP mode (?once), like a 1-second cron job
 *   sql        token   POST query=… → result sets (SQL console + test tools)
 *   configure  token   POST NAME=value … → rewrites define("NAME", …) in GameEngine/config.php
 *   reset      token   drops all game tables and the generated config, restores install/ → fresh installer
 *   startnow   token   if START_DATE/START_TIME lie in the future (in the world's TIMEZONE), moves them to now
 *
 * The token is the TZ_CONTROL_TOKEN environment variable, sent as the X-TZ-Token header.
 * Database credentials for reset/status come from TZ_DB_* (the same ones the installer gets).
 */

$tzRoot = rtrim((string)$_SERVER['DOCUMENT_ROOT'], '/');
$tzAction = (string)($GLOBALS['tzControlAction'] ?? '');
$tzT0 = microtime(true);

function tz_json(array $data, int $code = 200): void
{
    while (ob_get_level() > 0) {
        ob_end_clean();
    }
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE);
}

function tz_installed(string $root): bool
{
    return is_file("$root/var/installed") && is_file("$root/GameEngine/config.php");
}

/** Opens a mysqli connection with the TZ_DB_* credentials (the database may not have the game tables yet). */
function tz_db(): mysqli
{
    mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
    $db = new mysqli((string)getenv('TZ_DB_HOST') ?: 'localhost', (string)getenv('TZ_DB_USER'), (string)getenv('TZ_DB_PASSWORD'),
        (string)getenv('TZ_DB_NAME'), (int)(getenv('TZ_DB_PORT') ?: 3306));
    $db->set_charset('utf8mb4');
    return $db;
}

/** Value of define("NAME", …) in config.php, as written (string without quotes, or the raw expression). */
function tz_config_value(string $config, string $name): ?string
{
    if (preg_match('/define\(\s*["\']' . preg_quote($name, '/') . '["\']\s*,\s*("([^"]*)"|\'([^\']*)\'|[^)]*)\s*\)\s*;/', $config, $m)) {
        return isset($m[3]) && $m[3] !== '' ? $m[3] : (isset($m[2]) && $m[2] !== '' ? $m[2] : trim(trim($m[1]), '"\''));
    }
    return null;
}

if ($tzAction !== 'health') {
    $tzToken = (string)getenv('TZ_CONTROL_TOKEN');
    if ($tzToken === '' || !hash_equals($tzToken, (string)($_SERVER['HTTP_X_TZ_TOKEN'] ?? ''))) {
        tz_json(['ok' => false, 'error' => 'forbidden'], 403);
        return;
    }
}

// ------------------------------------------------------------------------------------------- health
if ($tzAction === 'health') {
    tz_json(['status' => tz_installed($tzRoot) ? 'ready' : 'install', 'php' => PHP_VERSION]);
    return;
}

// ------------------------------------------------------------------------------------------- status
if ($tzAction === 'status') {
    $out = ['ok' => true, 'installed' => tz_installed($tzRoot), 'config' => is_file("$tzRoot/GameEngine/config.php"),
            'installer' => is_file("$tzRoot/install/index.php"), 'php' => PHP_VERSION];
    if ($out['config']) {
        $cfg = (string)file_get_contents("$tzRoot/GameEngine/config.php");
        foreach (['SPEED', 'WORLD_MAX', 'SERVER_GP', 'HOMEPAGE', 'TB_PREFIX', 'SERVER_LANG', 'TIMEZONE', 'COMMENCE'] as $k) {
            $out['settings'][$k] = tz_config_value($cfg, $k);
        }
    }
    try {
        $db = tz_db();
        $out['db'] = ['ok' => true, 'version' => $db->server_info];
        $prefix = $out['settings']['TB_PREFIX'] ?? 's1_';
        $tables = (int)$db->query("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()")->fetch_row()[0];
        $out['db']['tables'] = $tables;
        if ($tables > 0 && $db->query("SHOW TABLES LIKE '" . $db->real_escape_string($prefix) . "users'")->num_rows) {
            $out['users'] = (int)$db->query("SELECT COUNT(*) FROM `{$prefix}users` WHERE id > 5")->fetch_row()[0];
            $out['villages'] = (int)$db->query("SELECT COUNT(*) FROM `{$prefix}vdata`")->fetch_row()[0];
            $out['tiles'] = (int)$db->query("SELECT COUNT(*) FROM `{$prefix}wdata`")->fetch_row()[0];
        }
    } catch (Throwable $e) {
        $out['db'] = ['ok' => false, 'error' => $e->getMessage()];
    }
    tz_json($out);
    return;
}

// ------------------------------------------------------------------------------------------- sql
if ($tzAction === 'sql') {
    $query = (string)($_POST['query'] ?? '');
    $out = ['ok' => true, 'sets' => [], 'affected' => 0];
    try {
        $db = tz_db();
        if ($query !== '' && $db->multi_query($query)) {
            do {
                if ($res = $db->store_result()) {
                    $cols = array_map(fn($f) => $f->name, $res->fetch_fields());
                    $rows = [];
                    while (($row = $res->fetch_row()) && count($rows) < 2000) {
                        $rows[] = array_map(fn($v) => $v === null ? 'NULL' : (string)$v, $row);
                    }
                    $out['sets'][] = ['columns' => $cols, 'rows' => $rows];
                    $res->free();
                } else {
                    $out['affected'] += max(0, $db->affected_rows);
                }
            } while ($db->more_results() && $db->next_result());
        }
    } catch (Throwable $e) {
        $out['error'] = $e->getMessage();
    }
    $out['ms'] = (int)round((microtime(true) - $tzT0) * 1000);
    tz_json($out);
    return;
}

// ------------------------------------------------------------------------------------------- configure
if ($tzAction === 'configure') {
    $file = "$tzRoot/GameEngine/config.php";
    if (!is_file($file)) {
        tz_json(['ok' => false, 'error' => 'not installed']);
        return;
    }
    $cfg = (string)file_get_contents($file);
    $changed = [];
    foreach ($_POST as $name => $value) {
        $name = (string)$name;
        $value = (string)$value;
        // world shape and database settings must not change under a running world
        if (!preg_match('/^[A-Z][A-Z0-9_]*$/', $name) || preg_match('/["\'\\\\\r\n]/', $value)
            || preg_match('/^(WORLD_MAX|TB_PREFIX|SQL_\w+|DB_TYPE|COMMENCE|CRON_KEY)$/', $name)) {
            continue;
        }
        $pattern = '/define\(\s*(["\'])' . preg_quote($name, '/') . '\1\s*,\s*("[^"]*"|\'[^\']*\'|[^)]*)\s*\)\s*;/';
        $cfg = preg_replace_callback($pattern, function ($m) use ($name, $value, &$changed) {
            $old = trim($m[2]);
            $quoted = $old !== '' && ($old[0] === '"' || $old[0] === "'");
            if (!$quoted && !preg_match('/^(true|false|-?\d+(\.\d+)?)$/i', $value)) {
                return $m[0];       // a bare expression may only become a number/boolean
            }
            $changed[] = $name;
            return 'define("' . $name . '", ' . ($quoted ? '"' . $value . '"' : $value) . ');';
        }, $cfg, 1);
    }
    file_put_contents($file, $cfg, LOCK_EX);
    if (function_exists('opcache_invalidate')) {
        @opcache_invalidate($file, true);
    }
    tz_json(['ok' => true, 'changed' => $changed]);
    return;
}

// ------------------------------------------------------------------------------------------- selftest
// String functions the game relies on, as built into this PHP (diagnostics for the iOS build).
if ($tzAction === 'selftest') {
    $name = 'Bravos Hrad';
    $r = [
        'php' => PHP_VERSION, 'pcre' => PCRE_VERSION, 'zts' => PHP_ZTS, 'os' => PHP_OS,
        'pcre_jit' => ini_get('pcre.jit'), 'mb_internal' => function_exists('mb_internal_encoding') ? mb_internal_encoding() : null,
        'ascii' => preg_match('/^[a-z ]+$/i', $name),
        'u_flag' => preg_match('/^[a-z ]+$/iu', $name),
        'prop_L' => preg_match('/^\p{L}+$/u', 'Bravos'),
        'prop_L_cz' => preg_match('/^\p{L}+$/u', 'Ořechov'),
        'game_pattern' => preg_match('/^[\p{L}\p{N}._\-\[\]()]+(?: [\p{L}\p{N}._\-\[\]()]+)*$/u', $name),
        'game_pattern_alt' => preg_match('/^(?:\\p{L}|\\p{N}|[._\\-\\[\\]()])+(?: (?:\\p{L}|\\p{N}|[._\\-\\[\\]()])+)*$/u', $name),
        'class_L' => preg_match('/^[\\p{L}]+$/u', 'Bravos'),
        'class_LN' => preg_match('/^[\\p{L}\\p{N}]+$/u', 'Bravos1'),
        'prop_N' => preg_match('/^\\p{N}+$/u', '123'),
        'class_L_dash' => preg_match('/^[\\p{L}\\-]+$/u', 'Bra-vos'),
        'negclass_L' => preg_replace('/[^\\p{L} ]/u', '#', 'Ab c!'),
        'preg_error' => preg_last_error_msg(),
        'replace_quote' => preg_replace("/['\x{2018}\x{2019}`\x{00B4}]/u", '', "Bravo\u{2019}s"),
        'replace_error' => preg_last_error_msg(),
        'mb_strlen' => function_exists('mb_strlen') ? mb_strlen('Ořechov', 'UTF-8') : null,
        'mb_substr' => function_exists('mb_substr') ? mb_substr('Ořechov město', 0, 7, 'UTF-8') : null,
    ];
    tz_json(['ok' => true] + $r);
    return;
}

// ------------------------------------------------------------------------------------------- startnow
if ($tzAction === 'startnow') {
    $file = "$tzRoot/GameEngine/config.php";
    if (!is_file($file)) {
        tz_json(['ok' => false, 'error' => 'not installed']);
        return;
    }
    $cfg = (string)file_get_contents($file);
    try {
        $tz = new DateTimeZone(tz_config_value($cfg, 'TIMEZONE') ?: date_default_timezone_get());
    } catch (Throwable $e) {
        $tz = new DateTimeZone('UTC');
    }
    $date = (string)tz_config_value($cfg, 'START_DATE');
    $time = (string)tz_config_value($cfg, 'START_TIME');
    $start = DateTime::createFromFormat('d.m.Y H:i', "$date $time", $tz);
    $now = new DateTime('now', $tz);
    $out = ['ok' => true, 'start' => "$date $time", 'moved' => false];
    if ($start === false || $start > $now) {
        $new = (clone $now)->modify('-1 minute');
        foreach (['START_DATE' => $new->format('d.m.Y'), 'START_TIME' => $new->format('H:i')] as $name => $value) {
            $cfg = preg_replace('/define\(\s*(["\'])' . $name . '\1\s*,\s*("[^"]*"|\'[^\']*\')\s*\)\s*;/',
                'define("' . $name . '", "' . $value . '");', $cfg, 1);
        }
        file_put_contents($file, $cfg, LOCK_EX);
        $out['moved'] = true;
        $out['start'] = $new->format('d.m.Y H:i');
    }
    tz_json($out);
    return;
}

// ------------------------------------------------------------------------------------------- reset
if ($tzAction === 'reset') {
    $out = ['ok' => true, 'dropped' => 0];
    try {
        $db = tz_db();
        $db->query('SET FOREIGN_KEY_CHECKS = 0');
        $tables = $db->query('SHOW TABLES')->fetch_all();
        foreach ($tables as [$table]) {
            $db->query('DROP TABLE `' . str_replace('`', '``', $table) . '`');
            $out['dropped']++;
        }
    } catch (Throwable $e) {
        tz_json(['ok' => false, 'error' => $e->getMessage()]);
        return;
    }
    foreach (['GameEngine/config.php', 'GameEngine/Admin/Mods/constant_format.tpl', 'var/installed', 'Templates/text.tpl'] as $f) {
        @unlink("$tzRoot/$f");
    }
    foreach (['GameEngine/Prevention', 'GameEngine/Notes'] as $dir) {
        foreach (glob("$tzRoot/$dir/*") ?: [] as $f) {
            if (is_file($f) && basename($f) !== 'index.php') {
                @unlink($f);
            }
        }
    }
    // The installer's last step renames install/ to installed_<time>/ – bring it back.
    if (!is_dir("$tzRoot/install")) {
        $old = glob("$tzRoot/installed_*", GLOB_ONLYDIR) ?: [];
        rsort($old);
        if ($old) {
            rename($old[0], "$tzRoot/install");
        }
    }
    foreach (glob("$tzRoot/installed_*", GLOB_ONLYDIR) ?: [] as $dir) {
        $out['leftover'][] = basename($dir);
    }
    $out['installer'] = is_file("$tzRoot/install/index.php");
    tz_json($out);
    return;
}

// ------------------------------------------------------------------------------------------- tick
if ($tzAction === 'tick') {
    if (!tz_installed($tzRoot)) {
        tz_json(['ok' => false, 'error' => 'not installed']);
        return;
    }
    // config.php starts a PHP session; reuse one fixed session so the tick does not create a file per call.
    session_id('tzcontroltick');
    @session_start();
    include_once "$tzRoot/GameEngine/config.php";
    $_GET['key'] = defined('CRON_KEY') ? CRON_KEY : '';
    $_GET['once'] = '1';
    $tzTickDone = false;
    register_shutdown_function(function () use (&$tzTickDone, $tzT0) {
        $err = error_get_last();
        $fatal = $err && in_array($err['type'], [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR, E_USER_ERROR], true);
        $output = '';
        while (ob_get_level() > 0) {
            $output = ob_get_clean() . $output;
        }
        @session_write_close();
        $res = ['ok' => !$fatal, 'ran' => $tzTickDone, 'ms' => (int)round((microtime(true) - $tzT0) * 1000)];
        if ($fatal) {
            $res['error'] = $err['message'] . ' @ ' . basename($err['file']) . ':' . $err['line'];
        }
        $output = trim(str_replace("OK\n", '', $output));
        if ($output !== '') {
            $res['output'] = mb_substr(strip_tags($output), 0, 2000);
        }
        if (!headers_sent()) {
            http_response_code(200);
            header_remove('Content-Type');
            header('Content-Type: application/json; charset=utf-8');
        }
        echo json_encode($res, JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE);
    });
    ob_start();
    require "$tzRoot/cron.php";
    $tzTickDone = true;
    return;
}

tz_json(['ok' => false, 'error' => 'unknown action'], 404);
