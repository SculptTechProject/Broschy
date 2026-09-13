#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# Accept the previous cache variable for existing local build scripts.
build_cache="${BROSCHY_BUILD_CACHE:-${NOTCHFLOW_BUILD_CACHE:-$PWD/.build}}"
swift build -c release --scratch-path "$build_cache"
bin_dir="$(swift build -c release --scratch-path "$build_cache" --show-bin-path)"
# Assemble only declared resources, so local files from an old bundle cannot ship.
mkdir -p "$PWD/build"
staging_dir="$(mktemp -d "$PWD/build/.bundle.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
app_dir="$staging_dir/Broschy.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/Broschy" "$app_dir/Contents/MacOS/Broschy"
cp "$bin_dir/broschy-cli" "$app_dir/Contents/MacOS/broschy-cli"
cp Info.plist "$app_dir/Contents/Info.plist"
cp Resources/Broschy.icns "$app_dir/Contents/Resources/Broschy.icns"
cp Resources/AppIcon.png "$app_dir/Contents/Resources/AppIcon.png"
mkdir -p "$app_dir/Contents/Resources/Integrations/opencode"
cp scripts/agent-integrations.py "$app_dir/Contents/Resources/Integrations/agent-integrations.py"
cp Integrations/opencode/broschy.js "$app_dir/Contents/Resources/Integrations/opencode/broschy.js"
cp docs/AGENTS.md "$app_dir/Contents/Resources/Integrations/Guide.md"
# SwiftPM release binaries retain N_SO/N_OSO debug records with build-machine
# paths. Remove those records before signing; runtime symbols remain available.
xcrun strip -S "$app_dir/Contents/MacOS/Broschy" "$app_dir/Contents/MacOS/broschy-cli"
codesign --force --sign - "$app_dir/Contents/MacOS/broschy-cli"
codesign --force --sign - "$app_dir"
python3 scripts/check-bundle-privacy.py "$app_dir"
final_app_dir="$PWD/build/Broschy.app"
if [ -e "$final_app_dir" ]; then mv "$final_app_dir" "$staging_dir/previous.app"; fi
if ! mv "$app_dir" "$final_app_dir"; then
    if [ -e "$staging_dir/previous.app" ]; then mv "$staging_dir/previous.app" "$final_app_dir"; fi
    exit 1
fi
printf '%s\n' "$final_app_dir"
