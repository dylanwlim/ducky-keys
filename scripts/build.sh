#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-release}"
mkdir -p dist
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
app="$staging/Ducky Keys.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
if [[ "$mode" == "universal" ]]; then
  swift build -c release --arch arm64 --arch x86_64
  bin="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
  swift build -c release
  bin="$(swift build -c release --show-bin-path)"
fi
cp "$bin/DuckyKeys" "$app/Contents/MacOS/DuckyKeys"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$app/Contents/Resources/"; fi
xattr -dr com.apple.FinderInfo "$app" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$app" 2>/dev/null || true
codesign --force --sign "${SIGNING_IDENTITY:--}" --options runtime "$app"
codesign --verify --strict "$app"
mkdir -p dist
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" dist/Ducky-Keys.zip
/usr/bin/ditto --norsrc --noextattr "$app" "dist/Ducky Keys.app"
(cd dist && shasum -a 256 Ducky-Keys.zip > SHA256SUMS.txt)
