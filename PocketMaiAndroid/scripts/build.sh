#!/bin/bash
set -euo pipefail
app_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source "$app_dir/scripts/environment.sh"
swift_command=$SWIFT
configuration=${CONFIGURATION:-debug}
abis=${ANDROID_ABIS:-arm64-v8a}

: "${ANDROID_HOME:?Android SDK not found; install it with Android Studio or set ANDROID_HOME}"
: "${ANDROID_NDK_HOME:?Android NDK 30 not found; install it with Android Studio or set ANDROID_NDK_HOME}"

sh "$app_dir/scripts/bootstrap.sh"
# SwiftPM's lock ends before runtime copying/Gradle packaging. Keep the whole
# APK pipeline exclusive so two make invocations cannot copy a relinking .so.
mkdir -p "$app_dir/.build"
lock_dir="$app_dir/.build/android-apk.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
  echo "An APK build is already running ($lock_dir)." >&2
  exit 1
fi
trap 'rmdir "$lock_dir"' EXIT
trap 'exit 130' INT TERM
# Locate the SDK's runtime libraries; builds may use a custom SDK directory.
sdk_search=${SWIFT_SDKS_PATH:-}
sdk_options=()
if [ -n "$sdk_search" ]; then
  sdk_options=(--swift-sdks-path "$sdk_search")
elif [ -d "$HOME/Library/org.swift.swiftpm/swift-sdks" ]; then
  sdk_search="$HOME/Library/org.swift.swiftpm/swift-sdks"
else
  sdk_search="${XDG_CONFIG_HOME:-$HOME/.config}/swiftpm/swift-sdks"
  [ -d "$sdk_search" ] || sdk_search="$HOME/.swiftpm/swift-sdks"
fi
sdk_root=${SWIFT_ANDROID_SDK_ROOT:-$sdk_search/$swift_sdk.artifactbundle/swift-android}
if [ ! -d "$sdk_root/swift-resources" ]; then
  echo "Cannot find Android SDK runtime at $sdk_root; set SWIFT_ANDROID_SDK_ROOT." >&2
  exit 1
fi

export PMAI_NO_VISUAL=1
for abi in $abis; do
  case "$abi" in
    arm64-v8a) architecture=aarch64 ;;
    x86_64) architecture=x86_64 ;;
    *) echo "Unsupported ABI: $abi" >&2; exit 1 ;;
  esac
  triple="$architecture-unknown-linux-android28"
  args=(--package-path "$app_dir" --build-system native --disable-sandbox
    --swift-sdk "$swift_sdk" --triple "$triple" -c "$configuration" "${sdk_options[@]}"
    -Xlinker "-L$sdk_root/swift-resources/usr/lib/swift_static-$architecture/android")
  "$swift_command" build "${args[@]}" --product SwiftAndroidApp
  bin_dir=$("$swift_command" build "${args[@]}" --show-bin-path)
  destination="$app_dir/app/src/main/jniLibs/$abi"
  mkdir -p "$destination"
  for library in "$bin_dir"/*.so "$sdk_root/swift-resources/usr/lib/swift-$architecture/android/"*.so; do
    case "$(basename "$library")" in
      libTesting.so|libXCTest.so|lib_Testing*.so) continue ;;
    esac
    cp "$library" "$destination/"
  done
  ndk_library=("$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/sysroot/usr/lib/"$architecture-linux-android/libc++_shared.so")
  cp "${ndk_library[0]}" "$destination/"
  for library in "$destination/"*.so; do
    if [ "$(od -An -tx1 -N4 "$library" | tr -d '[:space:]')" != 7f454c46 ]; then
      echo "Invalid native library copy: $library. Retry after other Swift builds finish." >&2
      exit 1
    fi
  done
done

# The dependency pins the Gradle version compatible with its plugins.
gradle_command=${GRADLE:-$app_dir/.deps/AndroidSwiftUI/gradlew}
"$gradle_command" -p "$app_dir" :app:clean :app:assembleDebug
echo "APK: $app_dir/app/build/outputs/apk/debug/app-debug.apk"
