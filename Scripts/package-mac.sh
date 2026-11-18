#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
out="$root/dist"
app="$out/Relay Workspace.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$root/.build"
tmp=$(mktemp -d "$root/.build/package.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
app_slices=()
cli_slices=()
for arch in ${RELAY_ARCHS:-$(uname -m)}; do
  case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1;; esac
  args=(-c release --triple "$arch-apple-macosx14.0")
  swift build "${args[@]}" --product RelayDesktop
  swift build "${args[@]}" --product relay
  bin=$(swift build "${args[@]}" --show-bin-path)
  app_slices+=("$bin/RelayDesktop")
  cli_slices+=("$bin/relay")
done
lipo -create "${app_slices[@]}" -output "$app/Contents/MacOS/RelayWorkspace"
lipo -create "${cli_slices[@]}" -output "$app/Contents/MacOS/relay"
icons="$tmp/Relay.iconset"
mkdir -p "$icons"
for size in 16 32 128 256 512; do
  cp "App/Assets.xcassets/AppIcon.appiconset/mac-$size.png" "$icons/icon_${size}x${size}.png"
  cp "App/Assets.xcassets/AppIcon.appiconset/mac-$((size*2)).png" "$icons/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$icons" -o "$app/Contents/Resources/Relay.icns"
cp Scripts/MacInfo.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app/Contents/MacOS/relay"
codesign --force --sign - "$app"
codesign --verify --strict --deep "$app"
mkdir -p "$tmp/image"
ditto "$app" "$tmp/image/Relay Workspace.app"
ln -s /Applications "$tmp/image/Applications"
hdiutil create -quiet -ov -format UDZO -volname "Relay Workspace" -srcfolder "$tmp/image" "$out/Relay-Workspace-macOS.dmg"
echo "$out/Relay-Workspace-macOS.dmg"
