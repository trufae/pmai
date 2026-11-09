#!/bin/sh
# One SwiftPM graph and one executable: the GUI launches itself in ACP mode.
set -eu
cd "$(dirname "$0")/.."
config=${CONFIG:-debug}
case "$config" in Debug|debug) config=debug ;; Release|release) config=release ;; *) echo "CONFIG must be debug or release" >&2; exit 1 ;; esac
if [ "${MAC_MLX:-0}" = 1 ]; then unset PMAI_NO_MLX; else export PMAI_NO_MLX=1; fi
swift_command=${SWIFT:-swift}
# A smaller dependency graph must not prune pins used by the iOS/full CLI build.
pins=$(mktemp -t pmai-mac-pins)
stage=""
had_pins=0
if [ -f MaiCore/Package.resolved ]; then
  had_pins=1
  cp MaiCore/Package.resolved "$pins"
fi
cleanup() {
  if [ "$had_pins" = 1 ]; then cp "$pins" MaiCore/Package.resolved; fi
  rm -f "$pins"
  if [ -n "$stage" ]; then rm -rf "$stage"; fi
}
trap cleanup EXIT
if [ "$config" = release ]; then set -- -Xswiftc -Osize; else set --; fi
"$swift_command" build --package-path MaiCore --build-system native --product pmai-mac -c "$config" --disable-index-store --disable-prefetching "$@"
binary_dir=$("$swift_command" build --package-path MaiCore --build-system native -c "$config" --show-bin-path --disable-prefetching)
app_destination="${MAC_APP:-build/pmai.app}"
case "$app_destination" in *.app) ;; *) echo "MAC_APP must name an .app bundle" >&2; exit 1 ;; esac
mkdir -p build
stage=$(mktemp -d build/pmai-mac.XXXXXX)
app="$stage/pmai.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/pmai-mac" "$app/Contents/MacOS/pmai"
iconset=build/pmai.iconset
mkdir -p "$iconset"
cp appIcons/icon-128.png "$iconset/icon_128x128.png"
cp appIcons/icon-256.png "$iconset/icon_128x128@2x.png"
cp appIcons/icon-256.png "$iconset/icon_256x256.png"
cp appIcons/icon-512.png "$iconset/icon_256x256@2x.png"
cp appIcons/icon-512.png "$iconset/icon_512x512.png"
cp appIcons/icon-1024.png "$iconset/icon_512x512@2x.png"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
if [ "$config" = release ]; then strip -x "$app/Contents/MacOS/pmai"; fi
version=$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' MaiCore/Sources/MaiCLI/MaiCLI.swift)
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>pmai</string>
<key>CFBundleDisplayName</key><string>pmai</string>
<key>CFBundleIdentifier</key><string>io.github.trufae.pmai.mac</string>
<key>CFBundleExecutable</key><string>pmai</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSMicrophoneUsageDescription</key><string>pmai uses the microphone for voice input.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>pmai transcribes voice input on your Mac.</string>
</dict></plist>
EOF
# MLX builds may produce resource bundles; copy only when they are present.
if [ "${MAC_MLX:-0}" = 1 ]; then
  python3 sys/build-mlx-metal.py --bin-dir "$binary_dir"
  if [ -f "$binary_dir/mlx.metallib" ]; then cp "$binary_dir/mlx.metallib" "$app/Contents/MacOS/"; fi
  for resource in "$binary_dir"/*.bundle; do
    [ -d "$resource" ] || continue
    cp -R "$resource" "$app/Contents/Resources/"
  done
fi
codesign --force --sign "${MAC_SIGN_IDENTITY:--}" "$app"
codesign --verify --strict "$app"
# Replace managed bundle contents so switching back to lean removes MLX assets.
mkdir -p "$app_destination"
rsync -a --delete "$app/" "$app_destination/"
echo "$app_destination"
