#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
export CONFIGURATION=${CONFIGURATION:-debug}
case "$CONFIGURATION" in
  debug) task=:app:assembleDebug; suffix=-debug ;;
  release) task=:app:assembleRelease; suffix= ;;
  *) echo 'Use CONFIGURATION=debug or release.' >&2; exit 1 ;;
esac
"$app_dir/gradlew" -p "$app_dir" "$task"
output="$app_dir/PocketMaiKotlin-0.1.0$suffix.apk"
cp "$app_dir/app/build/outputs/apk/$CONFIGURATION/app-$CONFIGURATION.apk" "$output"
echo "APK: $output"
