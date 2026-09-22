#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
echo 'The optional NVIDIA WebRTC library is separately licensed and is not part of Harbor MIT.'
echo 'Review: https://docs.omniverse.nvidia.com/ov-web-sdk/latest/common/legal.html'
echo 'Package: https://www.npmjs.com/package/@nvidia/omniverse-webrtc-streaming-library'
read -r -p 'Have you reviewed the applicable terms and have permission to use this library? Type yes: ' answer
if [ "$answer" != yes ]; then echo 'Nothing installed.'; exit 1; fi
command -v node >/dev/null || { echo 'Install Node.js 22 or later first.' >&2; exit 1; }
command -v npm >/dev/null || { echo 'npm is required.' >&2; exit 1; }
(cd viewer && npm ci && npm run build)
target="$HOME/Library/Application Support/HarborSSH/IsaacViewer"
if [ -e "$target" ]; then
    echo "An optional viewer is already installed at $target. Move it to Trash before replacing it." >&2
    exit 1
fi
mkdir -p "$(dirname "$target")"
staging="$(mktemp -d "$(dirname "$target")/.isaac-viewer.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto --norsrc viewer/dist "$staging"
test -s "$staging/index.html" && test -s "$staging/NVIDIA-LICENSE.txt"
mv "$staging" "$target"
echo "Installed: $target"
echo 'Choose Reload in Harbor. These generated assets are excluded from Git.'
