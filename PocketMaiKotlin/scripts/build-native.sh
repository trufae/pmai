#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
export PMAI_NO_MLX=1 PMAI_FORWIROH_PLATFORM=native
configuration=${CONFIGURATION:-debug}
abis=${ANDROID_ABIS:-arm64-v8a}
mkdir -p "$app_dir/.build"
lock="$app_dir/.build/apk.lock"
mkdir "$lock" 2>/dev/null || { echo 'Another native build is running.' >&2; exit 1; }
trap 'rmdir "$lock"' EXIT
trap 'exit 130' INT TERM
: "${ANDROID_NDK_HOME:?Install NDK 30 or set ANDROID_NDK_HOME}"
: "${SWIFT_ANDROID_SDK_ROOT:?Install the Swift 6.4 Android SDK}"
sdk_options=()
if [ -n "${SWIFT_SDKS_PATH:-}" ]; then sdk_options=(--swift-sdks-path "$SWIFT_SDKS_PATH"); fi
for abi in $abis; do
  case "$abi" in
    arm64-v8a) arch=aarch64 ;;
    x86_64) arch=x86_64 ;;
    *) echo "Unsupported Android ABI: $abi" >&2; exit 1 ;;
  esac
  args=(--package-path "$app_dir" --build-system native --disable-sandbox --disable-index-store --disable-prefetching
    --swift-sdk "$swift_sdk" --triple "$arch-unknown-linux-android28" -c "$configuration" "${sdk_options[@]}"
    -Xlinker "-L$SWIFT_ANDROID_SDK_ROOT/swift-resources/usr/lib/swift_static-$arch/android")
  "$SWIFT" build "${args[@]}" --product MaiKotlinBridge
  bin_dir=$("$SWIFT" build "${args[@]}" --show-bin-path)
  destination="$app_dir/bridge/build/generated/native/$configuration/$abi"
  mkdir -p "$destination"
  for library in "$bin_dir/"*.so "$SWIFT_ANDROID_SDK_ROOT/swift-resources/usr/lib/swift-$arch/android/"*.so \
    "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/sysroot/usr/lib/"$arch-linux-android/libc++_shared.so"; do
    case "$(basename "$library")" in libTesting.so|libXCTest.so|lib_Testing*.so) continue ;; esac
    if ! cmp -s "$library" "$destination/$(basename "$library")"; then cp "$library" "$destination/"; fi
  done
done
python3 "$app_dir/scripts/stage-bindings.py"
