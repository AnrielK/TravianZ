#!/usr/bin/env bash
# Cross-compiles PHP (CLI built-in web server as a library) + libpng + libjpeg for iOS.
# ZTS build: PHP keeps a virtual working directory (VIRTUAL_DIR), so chdir() in PHP never moves the
# process cwd that the in-process MariaDB server depends on.
# Extensions: everything TravianZ needs – mysqlnd/mysqli/pdo_mysql, mbstring, iconv, gd, session, filter, ctype.
# Output: ios/php/build/PHPCore.xcframework  (static lib, slices: iphoneos arm64, iphonesimulator arm64)
# The library exports  int php_cli_main(int argc, char **argv)  – same as running `php …` on the command line.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HERE/build"
SRC="$WORK/src"
MIN_IOS=16.0
PHP_BRANCH="${PHP_BRANCH:-8.3}"
PNG_VERSION=1.6.44
JPEG_VERSION=3.0.4
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
mkdir -p "$SRC"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

fetch() { # url dest
  [[ -f "$2" ]] || curl -fsSL --retry 3 "$1" -o "$2"
}

# ---------- sources ----------
log "Downloading sources"
PHP_VERSION="${PHP_VERSION:-$(curl -fsSL "https://www.php.net/releases/index.php?json&version=$PHP_BRANCH" | python3 -c 'import sys,json;print(json.load(sys.stdin)["version"])')}"
echo "PHP $PHP_VERSION, libpng $PNG_VERSION, libjpeg-turbo $JPEG_VERSION"
fetch "https://www.php.net/distributions/php-$PHP_VERSION.tar.xz" "$SRC/php.tar.xz"
fetch "https://github.com/pnggroup/libpng/archive/refs/tags/v$PNG_VERSION.tar.gz" "$SRC/libpng.tar.gz"
fetch "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$JPEG_VERSION/libjpeg-turbo-$JPEG_VERSION.tar.gz" "$SRC/libjpeg.tar.gz"
echo "$PHP_VERSION" > "$WORK/php-version.txt"

build_platform() {
  local PLATFORM="$1"           # iphoneos | iphonesimulator
  local TRIPLE SDK PREFIX B
  if [[ "$PLATFORM" == "iphoneos" ]]; then TRIPLE="arm64-apple-ios$MIN_IOS"; else TRIPLE="arm64-apple-ios$MIN_IOS-simulator"; fi
  SDK="$(xcrun --sdk "$PLATFORM" --show-sdk-path)"
  PREFIX="$WORK/$PLATFORM/prefix"
  B="$WORK/$PLATFORM"
  rm -rf "$B"; mkdir -p "$B" "$PREFIX"

  local CC_BIN; CC_BIN="$(xcrun --sdk "$PLATFORM" -f clang)"
  local CMAKE_COMMON=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES=arm64
                      -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_IOS -DCMAKE_INSTALL_PREFIX="$PREFIX"
                      -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="-target $TRIPLE")

  log "[$PLATFORM] libpng"
  mkdir -p "$B/libpng" && tar -xzf "$SRC/libpng.tar.gz" -C "$B/libpng" --strip-components=1
  cmake -S "$B/libpng" -B "$B/libpng/_b" "${CMAKE_COMMON[@]}" -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF \
        -DPNG_TOOLS=OFF -DPNG_EXECUTABLES=OFF -DPNG_FRAMEWORK=OFF -DPNG_HARDWARE_OPTIMIZATIONS=OFF > "$B/libpng.log" 2>&1
  cmake --build "$B/libpng/_b" --target install -j "$JOBS" >> "$B/libpng.log" 2>&1

  log "[$PLATFORM] libjpeg-turbo"
  mkdir -p "$B/libjpeg" && tar -xzf "$SRC/libjpeg.tar.gz" -C "$B/libjpeg" --strip-components=1
  cmake -S "$B/libjpeg" -B "$B/libjpeg/_b" "${CMAKE_COMMON[@]}" -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
        -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_SIMD=OFF -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF > "$B/libjpeg.log" 2>&1
  cmake --build "$B/libjpeg/_b" --target install -j "$JOBS" >> "$B/libjpeg.log" 2>&1

  log "[$PLATFORM] PHP $PHP_VERSION configure"
  mkdir -p "$B/php" && tar -xJf "$SRC/php.tar.xz" -C "$B/php" --strip-components=1
  cd "$B/php"
  # The CLI SAPI becomes a library: main() -> php_cli_main(); a weak main keeps the php binary linkable.
  python3 - <<'PY'
import re
p='sapi/cli/php_cli.c'; s=open(p).read()
s,n=re.subn(r'\nint main\(int argc, char \*argv\[\]\)', '\nint php_cli_main(int argc, char *argv[])', s, count=1)
assert n==1, 'main() not found in php_cli.c'
s+='\n__attribute__((weak)) int main(int argc, char *argv[]) { return php_cli_main(argc, argv); }\n'
open(p,'w').write(s)
# PHP shares the process with the MariaDB server threads: no process-wide SIGPROF timers
# (set_time_limit / max_execution_time) – a signal could land on a MariaDB thread.
p='Zend/zend_execute_API.c'; s=open(p).read()
import re
for sig in (r'static void zend_set_timeout_ex\(zend_long seconds, bool reset_signals\)(?: /\* \{\{\{ \*/)?\n\{',
            r'\nvoid zend_unset_timeout\(void\)(?: /\* \{\{\{ \*/)?\n\{'):
    s, n = re.subn(sig, lambda m: m.group(0) + '\n#ifdef PHP_IOS\n\treturn;\n#endif', s, count=1)
    assert n == 1, sig
open(p,'w').write(s)
PY

  # target + sysroot are part of CC so that the preprocessor checks (`$CC -E`) see the iOS SDK too
  export CC="$CC_BIN -target $TRIPLE -isysroot $SDK"
  export CPP="$CC -E"
  export CFLAGS="-O2 -I$PREFIX/include -DPHP_IOS=1"
  export CPPFLAGS="-I$PREFIX/include"
  export LDFLAGS="-L$PREFIX/lib"
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
  export ZLIB_CFLAGS="-I$SDK/usr/include" ZLIB_LIBS="-lz"
  export PNG_CFLAGS="-I$PREFIX/include" PNG_LIBS="-L$PREFIX/lib -lpng16 -lz"
  export JPEG_CFLAGS="-I$PREFIX/include" JPEG_LIBS="-L$PREFIX/lib -ljpeg"

  ./configure --host=arm-apple-darwin --build="$(uname -m)-apple-darwin" --prefix="$PREFIX/php" \
    --disable-all --enable-zts --enable-embed=static --enable-cli --disable-cgi --disable-phpdbg --disable-fpm \
    --without-pear --disable-opcache --without-pcre-jit --without-valgrind \
    --enable-session --enable-pdo --enable-ctype --enable-filter \
    --enable-mysqlnd --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd \
    --with-iconv="$SDK/usr" --enable-mbstring --disable-mbregex --with-zlib \
    --enable-gd --with-jpeg \
    > "$B/php-configure.log" 2>&1 || { cp config.log "$B/php-config.log"; return 1; }
  # APIs that exist in the SDK headers but are marked unavailable on iOS
  for macro in HAVE_POSIX_SPAWN_FILE_ACTIONS_ADDCHDIR_NP; do
    sed -i '' -e "s/^#define $macro 1$/\/* #undef $macro (unavailable on iOS) *\//" main/php_config.h
  done
  # sanity: type fallbacks mean the SDK headers were not seen
  if grep -qE '^#define (gid_t|uid_t|size_t|off_t) ' main/php_config.h; then
    grep -E '^#define (gid_t|uid_t|size_t|off_t) ' main/php_config.h; cp config.log "$B/php-config.log"; return 1
  fi

  log "[$PLATFORM] PHP make"
  make -k -j "$JOBS" > "$B/php-make.log" 2>&1 || { grep -E "error:" "$B/php-make.log" | sort -u | head -n 40; return 1; }

  log "[$PLATFORM] combine static library"
  local CLI_OBJS=(sapi/cli/php_cli.o sapi/cli/php_http_parser.o sapi/cli/php_cli_server.o sapi/cli/ps_title.o sapi/cli/php_cli_process_title.o)
  local objs=()
  for o in "${CLI_OBJS[@]}"; do
    if [[ -f "$o" ]]; then objs+=("$o")
    elif [[ -f "$(dirname "$o")/.libs/$(basename "$o")" ]]; then objs+=("$(dirname "$o")/.libs/$(basename "$o")")
    else echo "missing object $o"; find sapi/cli -name '*.o' | head; return 1; fi
  done
  libtool -static -o "$B/libphpcore.a" libs/libphp.a "${objs[@]}" "$PREFIX/lib/libpng16.a" "$PREFIX/lib/libjpeg.a"
  mkdir -p "$B/include" && cp "$HERE/PHPCore.h" "$B/include/" && cp "$HERE/module.modulemap" "$B/include/"
  cd "$HERE"
}

build_platform iphoneos
build_platform iphonesimulator

log "XCFramework"
rm -rf "$WORK/PHPCore.xcframework"
xcodebuild -create-xcframework \
  -library "$WORK/iphoneos/libphpcore.a" -headers "$WORK/iphoneos/include" \
  -library "$WORK/iphonesimulator/libphpcore.a" -headers "$WORK/iphonesimulator/include" \
  -output "$WORK/PHPCore.xcframework"
ls -la "$WORK/PHPCore.xcframework"/*
echo "OK PHP $PHP_VERSION"
