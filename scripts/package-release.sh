#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app_dir="$PWD/.build/Harbor.app"
if [ ! -x "$app_dir/Contents/MacOS/HarborSSH" ]; then
    echo 'Build first: bash scripts/build-app.sh release' >&2; exit 1
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
architecture="$(lipo -archs "$app_dir/Contents/MacOS/HarborSSH")"
case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported release architecture: $architecture" >&2; exit 1 ;; esac
viewer="$app_dir/Contents/Resources/HarborSSH_HarborSSH.bundle/Simulation/viewer"
if [ -d "$viewer/assets" ] || [ -f "$viewer/NVIDIA-LICENSE.txt" ]; then
    echo 'Public archives must not contain the separately licensed NVIDIA viewer.' >&2; exit 1
fi
staging="$(mktemp -d /private/tmp/harbor-release.XXXXXX)"
trap 'rm -rf "$staging"' EXIT
ditto --norsrc "$app_dir" "$staging/Harbor.app"
xattr -cr "$staging/Harbor.app"
codesign --verify --deep --strict "$staging/Harbor.app"
mkdir -p dist
archive="$PWD/dist/Harbor-${version}-macOS-${architecture}.zip"
ditto -c -k --norsrc --keepParent "$staging/Harbor.app" "$archive"
(cd dist && shasum -a 256 "$(basename "$archive")" > SHA256SUMS.txt)
# A familiar drag-to-Applications installer, with the same verified app as the ZIP.
ln -s /Applications "$staging/Applications"
cp docs/install-release.txt "$staging/INSTALL.txt"
cp docs/install-release.txt dist/INSTALL.txt
disk_image="$PWD/dist/Harbor-${version}-macOS-${architecture}.dmg"
hdiutil create -volname "Harbor $version" -srcfolder "$staging" -ov -format UDZO "$disk_image"
hdiutil verify "$disk_image"
(cd dist && shasum -a 256 "Harbor-${version}-macOS-${architecture}.zip" "Harbor-${version}-macOS-${architecture}.dmg" > SHA256SUMS.txt)
echo "Archive: $archive"
echo "Disk image: $disk_image"
cat dist/SHA256SUMS.txt
