#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
dest="${1:-$PWD/local/Claude-Guard-macOS.zip}"
mkdir -p "$(dirname "$dest")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
app="$tmp/IPClaudePanel.app"
mkdir -p "$app/Contents/"{MacOS,Resources/monitor}
cp -X panel/Info.plist "$app/Contents"
cp -X panel/AppIcon.icns panel/morelogin-guide.html panel/egress-test.html "$app/Contents/Resources"
cp -X src/*.py src/dashboard.html "$app/Contents/Resources/monitor/"
for arch in arm64 x86_64; do
 xcrun swiftc -module-cache-path "$tmp/cache" -target "${arch}-apple-macos12.0" panel/*.swift -o "$tmp/$arch"
done
lipo -create "$tmp/arm64" "$tmp/x86_64" -output "$app/Contents/MacOS/IPClaudePanel"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --norsrc --keepParent "$app" "$dest"
