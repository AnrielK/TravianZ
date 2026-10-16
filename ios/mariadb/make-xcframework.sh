#!/usr/bin/env bash
# Packs the two static MariaDB slices into MariaDBCore.xcframework. Headers live in a MariaDBCore/
# subfolder so they do not collide with PHPCore's include/module.modulemap in the app build.
set -euo pipefail
W="$(cd "$(dirname "$0")" && pwd)/build"
args=()
for p in iphoneos iphonesimulator; do
  rm -rf "$W/$p/headers"; mkdir -p "$W/$p/headers/MariaDBCore"
  cp "$W/$p/include/MariaDBCore.h" "$W/$p/include/module.modulemap" "$W/$p/headers/MariaDBCore/"
  args+=(-library "$W/$p/libmariadbcore.a" -headers "$W/$p/headers")
done
rm -rf "$W/MariaDBCore.xcframework"
xcodebuild -create-xcframework "${args[@]}" -output "$W/MariaDBCore.xcframework"
find "$W/MariaDBCore.xcframework" -maxdepth 4 | head -20
