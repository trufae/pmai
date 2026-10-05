#!/bin/bash
# Shared discovery for make and direct script builds. Explicit overrides win.
app_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# Also recognize the cache used to bootstrap this project's first Android build.
tool_caches=("$app_dir/.deps" /tmp/pmai-swift64)

is_jdk() {
  [ -x "$1/bin/java" ] && [ -x "$1/bin/javac" ] && [ -f "$1/release" ] || return 1
  local version
  version=$(sed -n 's/^JAVA_VERSION="\([0-9]*\).*$/\1/p' "$1/release")
  [ "$version" = 17 ] || [ "$version" = 21 ]
}

if [ -z "${JAVA_HOME:-}" ]; then
  java_candidates=(
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    "$HOME/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    /opt/android-studio/jbr /usr/local/android-studio/jbr
  )
  if [ -x /usr/libexec/java_home ]; then
    for version in 21 17; do
      java_candidates+=("$(/usr/libexec/java_home -v "$version" 2>/dev/null || true)")
    done
  fi
  java_candidates+=(
    "${GRADLE_USER_HOME:-$HOME/.gradle}"/jdks/*/*/Contents/Home
    "${GRADLE_USER_HOME:-$HOME/.gradle}"/jdks/*/*
    /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
    /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
    /usr/local/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
    /usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
    /usr/lib/jvm/* "$HOME/.sdkman/candidates/java/current"
  )
  for candidate in "${java_candidates[@]}"; do
    if is_jdk "$candidate"; then
      JAVA_HOME=$candidate
      break
    fi
  done
  if [ -z "${JAVA_HOME:-}" ] && command -v java >/dev/null 2>&1; then
    JAVA_HOME=$(java -XshowSettings:properties -version 2>&1 |
      sed -n 's/^[[:space:]]*java.home = //p')
  fi
fi
if ! is_jdk "${JAVA_HOME:-}"; then
  echo "No JDK 17 or 21 found. Install Android Studio or a JDK 17/21 (JAVA_HOME can override discovery)." >&2
  return 1
fi
export JAVA_HOME

is_swift() {
  local version
  version=$("$1" --version 2>/dev/null) || return 1
  [[ "$version" == *"Swift version 6.4."* || "$version" == *"Swift version 6.4 "* ]]
}

if [ -z "${SWIFT:-}" ]; then
  swift_candidates=(swift
    /Library/Developer/Toolchains/swift-6.4*.xctoolchain/usr/bin/swift
    "$HOME"/Library/Developer/Toolchains/swift-6.4*.xctoolchain/usr/bin/swift
    "$HOME"/.local/share/swiftly/toolchains/6.4*/usr/bin/swift
    "$HOME"/Library/Application\ Support/swiftly/toolchains/6.4*/usr/bin/swift
  )
  for cache in "${tool_caches[@]}"; do
    swift_candidates+=("$cache"/toolchain/usr/bin/swift
      "$cache"/toolchain/*.xctoolchain/usr/bin/swift
      "$cache"/toolchain/*/Payload/usr/bin/swift)
  done
  for candidate in "${swift_candidates[@]}"; do
    if is_swift "$candidate"; then
      SWIFT=$candidate
      break
    fi
  done
fi
if ! is_swift "${SWIFT:-}"; then
  echo "No Swift 6.4 toolchain found. Install the swift.org Swift 6.4 toolchain (SWIFT can override discovery)." >&2
  return 1
fi
export SWIFT

if [ -z "${ANDROID_HOME:-}" ]; then
  ANDROID_HOME=${ANDROID_SDK_ROOT:-}
  if [ -z "$ANDROID_HOME" ] && [ -f "$app_dir/local.properties" ]; then
    ANDROID_HOME=$(sed -n 's/^sdk\.dir=//p' "$app_dir/local.properties" |
      sed 's/\\ / /g; s/\\:/:/g; s/\\\\/\\/g')
  fi
  if [ -z "$ANDROID_HOME" ]; then
    for candidate in "$HOME/Library/Android/sdk" "$HOME/Android/Sdk" /opt/android-sdk /usr/lib/android-sdk; do
      if [ -d "$candidate" ]; then
        ANDROID_HOME=$candidate
        break
      fi
    done
  fi
fi
export ANDROID_HOME
export ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT:-$ANDROID_HOME}
export ADB=${ADB:-${ANDROID_HOME:+$ANDROID_HOME/platform-tools/adb}}

swift_sdk=${SWIFT_ANDROID_SDK:-swift-6.4.0-RELEASE_android}
if [ -z "${SWIFT_SDKS_PATH:-}" ]; then
  sdk_candidates=("$HOME/Library/org.swift.swiftpm/swift-sdks"
    "${XDG_CONFIG_HOME:-$HOME/.config}/swiftpm/swift-sdks" "$HOME/.swiftpm/swift-sdks"
    "${tool_caches[@]}")
  if [ -n "${SWIFT_ANDROID_SDK_ROOT:-}" ]; then
    sdk_candidates=("$(dirname -- "$(dirname -- "$SWIFT_ANDROID_SDK_ROOT")")")
  fi
  for candidate in "${sdk_candidates[@]}"; do
    if [ -d "$candidate/$swift_sdk.artifactbundle/swift-android/swift-resources" ]; then
      SWIFT_SDKS_PATH=$candidate
      break
    fi
  done
fi
if [ -n "${SWIFT_SDKS_PATH:-}" ]; then
  export SWIFT_SDKS_PATH
  export SWIFT_ANDROID_SDK_ROOT=${SWIFT_ANDROID_SDK_ROOT:-$SWIFT_SDKS_PATH/$swift_sdk.artifactbundle/swift-android}
fi

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  ANDROID_NDK_HOME=${ANDROID_NDK_ROOT:-}
  if [ -z "$ANDROID_NDK_HOME" ]; then
    ndk_candidates=("$ANDROID_HOME"/ndk/30.* "$ANDROID_HOME/ndk-bundle"
      "$ANDROID_HOME/android-ndk-r30" /opt/homebrew/share/android-ndk /usr/local/share/android-ndk)
    for cache in "${tool_caches[@]}"; do
      ndk_candidates+=("$cache/android-ndk-r30")
    done
    for candidate in "${ndk_candidates[@]}"; do
      if [ -f "$candidate/source.properties" ] &&
          grep -q '^Pkg.Revision = 30\.' "$candidate/source.properties"; then
        ANDROID_NDK_HOME=$candidate
        break
      fi
    done
  fi
fi
export ANDROID_NDK_HOME
export ANDROID_NDK_ROOT=${ANDROID_NDK_ROOT:-$ANDROID_NDK_HOME}
