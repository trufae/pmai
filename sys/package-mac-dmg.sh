#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

app=${MAC_APP:-build/pmai.app}
dmg=${MAC_DMG:-build/pmai.dmg}
case "$app" in *.app) ;; *) echo "MAC_APP must name an .app bundle" >&2; exit 1 ;; esac
case "$dmg" in *.dmg) ;; *) echo "MAC_DMG must name a .dmg file" >&2; exit 1 ;; esac
test -x "$app/Contents/MacOS/pmai"
codesign --verify --strict "$app"

# Keep the old image until its replacement has been signed and verified.
mkdir -p "$(dirname "$dmg")"
stage=$(mktemp -d "$(dirname "$dmg")/.pmai-dmg.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/volume"
ditto "$app" "$stage/volume/pmai.app"
ln -s /Applications "$stage/volume/Applications"
hdiutil create -volname pmai -srcfolder "$stage/volume" -fs HFS+ \
  -format UDZO "$stage/pmai.dmg"
codesign --force --sign "${MAC_SIGN_IDENTITY:--}" "$stage/pmai.dmg"
codesign --verify --strict "$stage/pmai.dmg"
hdiutil verify "$stage/pmai.dmg"
mv -f "$stage/pmai.dmg" "$dmg"
echo "$dmg"
