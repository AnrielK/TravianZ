<?php
/*
 * Router for PHP's built-in web server – replaces Apache for TravianZ on iOS (and in scripts/run-local.sh).
 *
 *   php -S 127.0.0.1:8080 -t <TravianZ root> ios/runtime/router.php
 *
 * Reproduces what Apache + the .htaccess files do for TravianZ:
 *   - *.tpl, *.sql, *.log and everything under var/ are forbidden,
 *   - a directory serves its index.php (Admin/ serves admin.php, see Admin/.htaccess),
 *   - static files get long-lived caching, PHP pages get no-store,
 *   - every PHP script runs with the working directory set to its own folder (TravianZ resolves all of its
 *     includes relative to the current directory, like Apache's mod_php does).
 * plus the local control endpoint /__tz/<action> (control.php, protected by the TZ_CONTROL_TOKEN header).
 *
 * Symlinks inside the root are allowed on purpose: the iOS app links the read-only image folders from its
 * bundle into the writable document root.
 */

declare(strict_types=1);

function tz_route(): array|bool
{
    $root = rtrim((string)($_SERVER['DOCUMENT_ROOT'] ?? ''), '/');
    $path = rawurldecode((string)(parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/'));

    // ---- /__tz/<action>  (local control endpoint) -----------------------------------------------
    if (preg_match('#^/__tz/([a-z]+)$#', $path, $m)) {
        $GLOBALS['tzControlAction'] = $m[1];
        return [__DIR__ . '/control.php', '/__tz/' . $m[1]];
    }

    // ---- security: no hidden segments, no traversal, Apache <Files> deny rules --------------------
    $relative = ltrim($path, '/');
    foreach (explode('/', $relative) as $segment) {
        if ($segment === '..' || ($segment !== '' && $segment[0] === '.')) {
            return tz_deny(403);
        }
    }
    if (preg_match('#\.(tpl|sql|log|lck|lock)$#i', $relative) || preg_match('#^var(/|$)#', $relative)
        || preg_match('#^GameEngine/(Prevention|Notes)(/|$)#', $relative)) {
        return tz_deny(403);
    }

    $file = $root . '/' . $relative;
    if (is_dir($file)) {
        if ($relative !== '' && !str_ends_with($path, '/')) {
            header('Location: ' . $path . '/' . (isset($_SERVER['QUERY_STRING']) && $_SERVER['QUERY_STRING'] !== '' ? '?' . $_SERVER['QUERY_STRING'] : ''), true, 301);
            return true;
        }
        $dir = rtrim($file, '/');
        foreach (['index.php', 'admin.php', 'index.html'] as $index) {
            if (is_file("$dir/$index")) {
                $file = "$dir/$index";
                $relative = ltrim(rtrim($relative, '/') . '/' . $index, '/');
                break;
            }
        }
        if (is_dir($file)) {
            return tz_deny(403);
        }
    }
    if (!is_file($file)) {
        return tz_deny(404);
    }
    if (str_ends_with(strtolower($file), '.php')) {
        header('Cache-Control: no-cache, no-store, must-revalidate');
        return [$file, '/' . $relative];
    }
    return tz_static($file);
}

function tz_deny(int $code): bool
{
    http_response_code($code);
    header('Content-Type: text/plain; charset=utf-8');
    echo $code === 404 ? "Not Found\n" : "Forbidden\n";
    return true;
}

function tz_mime(string $file): string
{
    static $types = [
        'css' => 'text/css', 'js' => 'application/javascript', 'json' => 'application/json',
        'html' => 'text/html; charset=utf-8', 'htm' => 'text/html; charset=utf-8', 'txt' => 'text/plain; charset=utf-8',
        'xml' => 'application/xml', 'png' => 'image/png', 'gif' => 'image/gif', 'jpg' => 'image/jpeg',
        'jpeg' => 'image/jpeg', 'svg' => 'image/svg+xml', 'ico' => 'image/x-icon', 'webp' => 'image/webp',
        'woff' => 'font/woff', 'woff2' => 'font/woff2', 'ttf' => 'font/ttf', 'eot' => 'application/vnd.ms-fontobject',
        'otf' => 'font/otf', 'swf' => 'application/x-shockwave-flash', 'mp3' => 'audio/mpeg', 'ogg' => 'audio/ogg',
        'wav' => 'audio/wav', 'mp4' => 'video/mp4', 'pdf' => 'application/pdf', 'cur' => 'image/x-icon',
    ];
    return $types[strtolower(pathinfo($file, PATHINFO_EXTENSION))] ?? 'application/octet-stream';
}

function tz_static(string $file): bool
{
    $mtime = (int)filemtime($file);
    $size = (int)filesize($file);
    $etag = '"' . dechex($mtime) . '-' . dechex($size) . '"';
    header('Content-Type: ' . tz_mime($file));
    header('Last-Modified: ' . gmdate('D, d M Y H:i:s', $mtime) . ' GMT');
    header('ETag: ' . $etag);
    // .htaccess: images 30 days, css/js 7 days
    header('Cache-Control: public, max-age=' . (preg_match('/\.(css|js)$/i', $file) ? 604800 : 2592000));
    if (($_SERVER['HTTP_IF_NONE_MATCH'] ?? '') === $etag) {
        http_response_code(304);
        return true;
    }
    header('Content-Length: ' . $size);
    if (($_SERVER['REQUEST_METHOD'] ?? 'GET') !== 'HEAD') {
        readfile($file);
    }
    return true;
}

$tzTarget = tz_route();
if (!is_array($tzTarget)) {
    return $tzTarget;
}
// Execute in GLOBAL scope (TravianZ creates its objects at file scope and reads them via `global`).
$_SERVER['SCRIPT_FILENAME'] = $tzTarget[0];
$_SERVER['SCRIPT_NAME'] = $tzTarget[1];
$_SERVER['PHP_SELF'] = $tzTarget[1];
if (!isset($GLOBALS['tzControlAction'])) {
    chdir(dirname($tzTarget[0]));
}
unset($tzTarget[1]);
require $tzTarget[0];
