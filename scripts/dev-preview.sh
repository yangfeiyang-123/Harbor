#!/bin/bash
# Build a debug Harbor with its own bundle identifier, data folder and QA probe,
# then launch it next to the installed app. Nothing here touches the real
# profile in ~/Library/Application Support/HarborSSH except reading the
# verified Code-OSS runtime, which is cloned (copy-on-write) to skip a 200 MB
# download.
set -euo pipefail
cd "$(dirname "$0")/.."
# HARBOR_PREVIEW_OPTIMIZED=1 measures what a release build would feel like: optimized code
# that still carries the QA probe, built apart from the ordinary debug and release products.
if [ -n "${HARBOR_PREVIEW_OPTIMIZED:-}" ]; then flags=(-c release -Xswiftc -DDEBUG --scratch-path .build/optimized-preview)
else flags=(-c debug); fi
swift build "${flags[@]}" --disable-sandbox --build-system native 2>&1 | tail -25
bin="$(swift build "${flags[@]}" --show-bin-path --disable-sandbox --build-system native)"
work="${HARBOR_PREVIEW_WORK:-$PWD/.build/claude}"
# Documents can reattach Finder metadata that breaks signing; assemble on /private/tmp.
app="/private/tmp/harbor-preview-$(id -u)/HarborPreview.app"; data="$work/preview-data"; probe="$work/probe"; qa="$data/qa"
pkill -f "$app/Contents/MacOS/HarborSSH" 2>/dev/null || true
sleep 0.5
rm -rf "$app" "$probe"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$probe" "$qa/WorkSpace/src" "$qa/.state/CodeOSS"
cp "$bin/HarborSSH" "$app/Contents/MacOS/HarborSSH"
for bundle in "$bin"/*.bundle; do [ -d "$bundle" ] && ditto "$bundle" "$app/Contents/Resources/$(basename "$bundle")"; done
cp Resources/Info.plist "$app/Contents/Info.plist"
plist="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.harbor.ssh.preview" -c "Set :CFBundleName HarborPreview" \
  -c "Set :CFBundleDisplayName HarborPreview" -c "Add :HarborPreviewDataDirectory string $data" \
  -c "Add :HarborQAProbe string $probe" "$plist"
if [ "${1:-qa}" = "qa" ]; then /usr/libexec/PlistBuddy -c "Add :HarborQARoot string $qa" "$plist"; fi
if [ ! -f "$qa/WorkSpace/main.py" ]; then
  printf '# Greet every agent docked in the harbor\ndef greet(agents: list[str]) -> None:\n    for name in agents:\n        print(f"hello, {name}")\n\n\ngreet(["claude", "codex", "grok", "gemini"])\n' > "$qa/WorkSpace/main.py"
  printf '# Harbor demo\n\nA small workspace for previews.\n' > "$qa/WorkSpace/README.md"
  printf 'export const answer = 42;\n' > "$qa/WorkSpace/src/index.ts"
fi
source_runtime="$HOME/Library/Application Support/HarborSSH/CodeOSS/runtimes"
if [ -d "$source_runtime" ] && [ ! -d "$qa/.state/CodeOSS/runtimes" ]; then cp -Rc "$source_runtime" "$qa/.state/CodeOSS/runtimes"; fi
xattr -cr "$app"
codesign --force --deep --sign - "$app" 2>&1 | tail -2
# HARBOR_PREVIEW_NO_LAUNCH=1 builds the bundle and leaves starting it to the caller.
if [ -z "${HARBOR_PREVIEW_NO_LAUNCH:-}" ]; then open -n "$app"; echo "Launched $app"; fi
