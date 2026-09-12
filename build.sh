#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# Accept the previous cache variable for existing local build scripts.
build_cache="${BROSCHY_BUILD_CACHE:-${NOTCHFLOW_BUILD_CACHE:-$PWD/.build}}"
swift build -c release --scratch-path "$build_cache"
bin_dir="$(swift build -c release --scratch-path "$build_cache" --show-bin-path)"
app_dir="$PWD/build/Broschy.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/Broschy" "$app_dir/Contents/MacOS/Broschy"
cp "$bin_dir/broschy-cli" "$app_dir/Contents/MacOS/broschy-cli"
cp Info.plist "$app_dir/Contents/Info.plist"
cp Resources/Broschy.icns "$app_dir/Contents/Resources/Broschy.icns"
cp Resources/AppIcon.png "$app_dir/Contents/Resources/AppIcon.png"
codesign --force --sign - "$app_dir/Contents/MacOS/broschy-cli"
codesign --force --sign - "$app_dir"
printf '%s\n' "$app_dir"
