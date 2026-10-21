#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) echo 'Usage: bash scripts/build-app.sh [debug|release]' >&2; exit 2 ;; esac
swift build -c "$configuration" --disable-sandbox --build-system native
binary_dir="$(swift build -c "$configuration" --show-bin-path --disable-sandbox --build-system native)"
app_dir="$PWD/.build/Harbor.app"
# Start from an empty bundle so resources removed from the package never linger.
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" .build/Harbor.iconset
cp "$binary_dir/HarborSSH" "$app_dir/Contents/MacOS/HarborSSH"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp vendor/SwiftTerm/LICENSE "$app_dir/Contents/Resources/SwiftTerm-LICENSE.txt"
cp Resources/LiquidGlass-SOURCES.txt "$app_dir/Contents/Resources/LiquidGlass-SOURCES.txt"
for bundle in "$binary_dir"/*.bundle; do
    [ -d "$bundle" ] || continue
    ditto "$bundle" "$app_dir/Contents/Resources/$(basename "$bundle")"
done
swift Resources/draw-icon.swift .build/Harbor.iconset
iconutil -c icns .build/Harbor.iconset -o "$app_dir/Contents/Resources/Harbor.icns"
# Documents can acquire Finder/File Provider metadata while signing. Sign the
# completed bundle on the local temporary volume, then copy it without forks.
signing_dir="$(mktemp -d /private/tmp/harbor-sign.XXXXXX)"
trap 'rm -rf "$signing_dir"' EXIT
ditto --norsrc "$app_dir" "$signing_dir/Harbor.app"
xattr -cr "$signing_dir/Harbor.app"
codesign --force --deep --sign - "$signing_dir/Harbor.app"
codesign --verify --deep --strict "$signing_dir/Harbor.app"
ditto --norsrc "$signing_dir/Harbor.app" "$app_dir"
echo "Built: $app_dir"
