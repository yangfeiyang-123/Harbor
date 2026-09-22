#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) echo 'Usage: bash scripts/build-app.sh [debug|release]' >&2; exit 2 ;; esac
export SWIFTTERM_BUILD_COMMIT=5d14406844143538cd8f8851d2d8a67c1fe443e5
export SWIFTTERM_BUILD_BRANCH=harbor-vendored
export SWIFTTERM_BUILD_DIRTY=true
swift build -c "$configuration" --disable-sandbox --build-system native \
    -Xswiftc -debug-prefix-map -Xswiftc "$HOME=/Build" \
    -Xswiftc -file-prefix-map -Xswiftc "$PWD=/Harbor"
binary_dir="$(swift build -c "$configuration" --show-bin-path --disable-sandbox --build-system native)"
app_dir="$PWD/.build/Harbor.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" .build/Harbor.iconset
cp "$binary_dir/HarborSSH" "$app_dir/Contents/MacOS/HarborSSH"
if [ "$configuration" = release ]; then strip -S "$app_dir/Contents/MacOS/HarborSSH"; fi
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp vendor/SwiftTerm/LICENSE "$app_dir/Contents/Resources/SwiftTerm-LICENSE.txt"
cp Resources/LiquidGlass-SOURCES.txt "$app_dir/Contents/Resources/LiquidGlass-SOURCES.txt"
cp LICENSE "$app_dir/Contents/Resources/Harbor-LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$app_dir/Contents/Resources/THIRD_PARTY_NOTICES.md"
for bundle in "$binary_dir"/*.bundle; do
    [ -d "$bundle" ] || continue
    ditto "$bundle" "$app_dir/Contents/Resources/$(basename "$bundle")"
done
swift Resources/draw-icon.swift .build/Harbor.iconset
chmod 755 "$app_dir/Contents/MacOS/HarborSSH"
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
