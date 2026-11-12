#!/bin/sh
# SwiftPM compiles the existing lean Mac graph; Xcode owns the app and its signature.
set -eu
cd "$SRCROOT"

# The existing SwiftPM packaging builds for the host, as do the per-architecture CI jobs.
if [ "$ARCHS" != "$(uname -m)" ]; then
  echo "error: MaiMac builds for this Mac's architecture. Select My Mac and restore the target's default Architectures setting." >&2
  exit 1
fi

app="$TARGET_TEMP_DIR/SwiftPM/pmai.app"
export MAC_APP="$app" CONFIG="$CONFIGURATION" MAC_MLX=0 MAC_SIGN_IDENTITY=-
export SWIFT="$(xcrun --find swift)"
if [ "$DEBUG_INFORMATION_FORMAT" = dwarf-with-dsym ]; then
  export MAC_DSYM="$DWARF_DSYM_FOLDER_PATH/$DWARF_DSYM_FILE_NAME"
fi
sh sys/build-mac-app.sh

# Leave Info.plist, signing and archive metadata to the native Xcode app target.
mkdir -p "$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
cp "$app/Contents/MacOS/pmai" "$TARGET_BUILD_DIR/$EXECUTABLE_PATH"
rsync -a --delete "$app/Contents/Resources/" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/"
