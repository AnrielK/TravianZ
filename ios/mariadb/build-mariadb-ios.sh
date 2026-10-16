#!/usr/bin/env bash
# Cross-compiles the MariaDB server for iOS as a static library.
#   build-mariadb-ios.sh [iphoneos|iphonesimulator|all]   -> build/<platform>/libmariadbcore.a + include/
#   build-mariadb-ios.sh xcframework                      -> build/MariaDBCore.xcframework
# Also writes build/share/ (errmsg.sys + charsets, bundled into the app).
# The library exports  int ov_mariadbd_main(int argc, char **argv)  (C wrapper of the server's mysqld_main); the app
# runs it on a background thread, exactly like `mariadbd --datadir=… --socket=…`.
#
# Needs: Xcode, cmake, ninja, bison (Homebrew), python3, curl. Takes ~30–40 min on a CI runner.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HERE/build"
SRC_DIR="$WORK/src"
MARIADB_VERSION="${MARIADB_VERSION:-11.4.9}"
PCRE2_VERSION=10.45
MIN_IOS=16.0
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
mkdir -p "$SRC_DIR"
export PATH="$(brew --prefix bison 2>/dev/null || echo /opt/homebrew/opt/bison)/bin:$PATH"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fetch() { [[ -f "$2" ]] || curl -fsSL --retry 3 "$1" -o "$2"; }

if [[ "${1:-all}" == "xcframework" ]]; then :; else
log "Sources: MariaDB $MARIADB_VERSION, PCRE2 $PCRE2_VERSION"
fetch "https://archive.mariadb.org/mariadb-$MARIADB_VERSION/source/mariadb-$MARIADB_VERSION.tar.gz" "$SRC_DIR/mariadb.tar.gz"
fetch "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VERSION/pcre2-$PCRE2_VERSION.tar.gz" "$SRC_DIR/pcre2.tar.gz"
MDB="$SRC_DIR/mariadb-$MARIADB_VERSION"
if [[ ! -d "$MDB" ]]; then
  tar -xzf "$SRC_DIR/mariadb.tar.gz" -C "$SRC_DIR"
  python3 "$HERE/patch-source.py" "$MDB"
fi
echo "$MARIADB_VERSION" > "$WORK/mariadb-version.txt"

# ---------- 1. host tools (comp_err, gen_lex_hash, …) needed while cross-compiling ----------
HOST="$WORK/host"
if [[ ! -f "$HOST/import_executables.cmake" ]]; then
  log "Host build of import_executables"
  cmake -S "$MDB" -B "$HOST" -G Ninja -C "$HERE/mariadb-options.cmake" \
        -DWITH_PCRE=bundled -DWITH_LIBFMT=bundled > "$WORK/host-configure.log" 2>&1 \
    || { tail -n 60 "$WORK/host-configure.log"; exit 1; }
  cmake --build "$HOST" --target import_executables -j "$JOBS" > "$WORK/host-build.log" 2>&1 \
    || { grep -E "error|Error" "$WORK/host-build.log" | head -40; exit 1; }
fi
fi

build_platform() {
  local PLATFORM="$1"
  local TRIPLE SDK B PREFIX
  if [[ "$PLATFORM" == "iphoneos" ]]; then TRIPLE="arm64-apple-ios$MIN_IOS"; else TRIPLE="arm64-apple-ios$MIN_IOS-simulator"; fi
  SDK="$(xcrun --sdk "$PLATFORM" --show-sdk-path)"
  B="$WORK/$PLATFORM"
  PREFIX="$B/prefix"
  rm -rf "$B"; mkdir -p "$B" "$PREFIX"
  local IOS_CMAKE=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES=arm64
                   -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_IOS -DCMAKE_C_FLAGS="-target $TRIPLE"
                   -DCMAKE_CXX_FLAGS="-target $TRIPLE")

  log "[$PLATFORM] PCRE2"
  mkdir -p "$B/pcre2" && tar -xzf "$SRC_DIR/pcre2.tar.gz" -C "$B/pcre2" --strip-components=1
  cmake -S "$B/pcre2" -B "$B/pcre2/_b" -G Ninja "${IOS_CMAKE[@]}" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" -DBUILD_SHARED_LIBS=OFF -DPCRE2_BUILD_TESTS=OFF \
        -DPCRE2_BUILD_PCRE2GREP=OFF -DPCRE2_SUPPORT_JIT=OFF > "$B/pcre2.log" 2>&1
  cmake --build "$B/pcre2/_b" --target install -j "$JOBS" >> "$B/pcre2.log" 2>&1

  log "[$PLATFORM] MariaDB configure"
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
  cmake -S "$MDB" -B "$B/mariadb" -G Ninja -C "$HERE/mariadb-options.cmake" "${IOS_CMAKE[@]}" \
        -DIMPORT_EXECUTABLES="$HOST/import_executables.cmake" \
        -DCMAKE_FIND_ROOT_PATH="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX" \
        -DCMAKE_C_FLAGS="-target $TRIPLE -DMY_IOS=1 -I$PREFIX/include" -DCMAKE_CXX_FLAGS="-target $TRIPLE -DMY_IOS=1 -I$PREFIX/include" \
        -DCMAKE_EXE_LINKER_FLAGS="-L$PREFIX/lib" \
        -DWITH_PCRE=system -DWITH_LIBFMT=bundled -DSTACK_DIRECTION=-1 \
        -DHAVE_SYSTEM_LIBFMT=0 -DWITH_READLINE=OFF \
        > "$B/mariadb-configure.log" 2>&1 \
    || { cp "$B/mariadb/CMakeFiles/CMakeError.log" "$B/" 2>/dev/null; tail -n 80 "$B/mariadb-configure.log"; return 1; }
  unset PKG_CONFIG_LIBDIR

  log "[$PLATFORM] MariaDB build (mariadbd)"
  # -k 0: keep going, so one CI run reports every compile error at once
  cmake --build "$B/mariadb" --target mariadbd -j "$JOBS" -- -k 0 > "$B/mariadb-build.log" 2>&1 \
    || { grep -E "error:|Error [0-9]|FAILED" "$B/mariadb-build.log" | sort -u | head -n 60; return 1; }

  log "[$PLATFORM] combine static library"
  # The final link line of mariadbd lists every object and archive the server needs.
  (cd "$B/mariadb" && ninja -t commands mariadbd | tail -n 1) > "$B/link-command.txt"
  python3 - "$B" "$PREFIX" <<'PY'
import os, shlex, sys
b, prefix = sys.argv[1], sys.argv[2]
cmd = shlex.split(next(seg for seg in open(os.path.join(b, "link-command.txt")).read().split("&&") if "main.cc.o" in seg))
root = os.path.join(b, "mariadb")
inputs = []
for t in cmd:
    if t.endswith((".a", ".o")) and not t.endswith("main.cc.o"):
        p = t if os.path.isabs(t) else os.path.join(root, t)
        if os.path.exists(p) and p not in inputs:
            inputs.append(p)
for extra in ("libpcre2-8.a", "libpcre2-posix.a"):
    p = os.path.join(prefix, "lib", extra)
    if os.path.exists(p):
        inputs.append(p)
open(os.path.join(b, "inputs.txt"), "w").write("\n".join(inputs) + "\n")
print(f"{len(inputs)} inputs")
PY
  # mysqld_main() is C++ (mangled); export a plain C entry point for Swift.
  cat > "$B/ov_entry.cc" <<'CC'
int mysqld_main(int argc, char **argv);
extern "C" int ov_mariadbd_main(int argc, char **argv) { return mysqld_main(argc, argv); }
CC
  xcrun --sdk "$PLATFORM" clang++ -target "$TRIPLE" -isysroot "$SDK" -O2 -c "$B/ov_entry.cc" -o "$B/ov_entry.o"
  echo "$B/ov_entry.o" >> "$B/inputs.txt"
  xargs libtool -static -no_warning_for_no_symbols -o "$B/libmariadbcore.a" < "$B/inputs.txt"
  nm -gU "$B/libmariadbcore.a" > "$B/exported-symbols.txt" 2>/dev/null || true
  grep -q " _ov_mariadbd_main$" "$B/exported-symbols.txt" || { echo "ov_mariadbd_main not exported"; return 1; }
  mkdir -p "$B/include" && cp "$HERE/MariaDBCore.h" "$B/include/" && cp "$HERE/module.modulemap" "$B/include/"

  # errmsg.sys and charsets (identical for both platforms)
  if [[ ! -d "$WORK/share" ]]; then
    mkdir -p "$WORK/share"
    (cd "$B/mariadb/sql/share" && find . -name errmsg.sys | while read -r f; do mkdir -p "$WORK/share/$(dirname "$f")"; cp "$f" "$WORK/share/$f"; done)
    cp -R "$MDB/sql/share/charsets" "$WORK/share/charsets"
  fi
}

make_xcframework() {
  log "XCFramework"
  rm -rf "$WORK/MariaDBCore.xcframework"
  xcodebuild -create-xcframework \
    -library "$WORK/iphoneos/libmariadbcore.a" -headers "$WORK/iphoneos/include" \
    -library "$WORK/iphonesimulator/libmariadbcore.a" -headers "$WORK/iphonesimulator/include" \
    -output "$WORK/MariaDBCore.xcframework"
  du -sh "$WORK/MariaDBCore.xcframework" "$WORK/share"
}

case "${1:-all}" in
  iphoneos|iphonesimulator) build_platform "$1" ;;
  xcframework) make_xcframework ;;
  all) build_platform iphoneos; build_platform iphonesimulator; make_xcframework ;;
  *) echo "usage: $0 [iphoneos|iphonesimulator|xcframework|all]"; exit 64 ;;
esac
echo "OK MariaDB $MARIADB_VERSION ${1:-all}"
