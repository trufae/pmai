#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PBXPROJ="$SCRIPT_DIR/PocketMai.xcodeproj/project.pbxproj"
MAICLI="$SCRIPT_DIR/MaiCore/Sources/mai/MaiCLI.swift"

if [ ! -f "$PBXPROJ" ]; then
  printf '%s\n' "version.sh: missing project file: $PBXPROJ" >&2
  exit 1
fi

if [ ! -f "$MAICLI" ]; then
  printf '%s\n' "version.sh: missing source file: $MAICLI" >&2
  exit 1
fi

current_version=$(awk -F'= ' '
  /MARKETING_VERSION = / {
    gsub(/;[[:space:]]*$/, "", $2)
    print $2
    exit
  }
' "$PBXPROJ")

if [ "$#" -eq 0 ]; then
  printf '%s\n' "$current_version"
  exit 0
fi

new_version=$1

if ! printf '%s\n' "$new_version" | grep -Eq '^[0-9]+(\.[0-9]+){2}$'; then
  printf '%s\n' "version.sh: expected version in the form X.Y.Z, got: $new_version" >&2
  exit 1
fi

cli_version=$(awk -F'"' '/private static let version = "/ { print $2; exit }' "$MAICLI")

if [ -z "$cli_version" ]; then
  printf '%s\n' "version.sh: could not find version string in $MAICLI" >&2
  exit 1
fi

cli_matches=$(grep -c 'private static let version = "' "$MAICLI" || true)

if [ "$cli_matches" -ne 1 ]; then
  printf '%s\n' "version.sh: expected exactly one version string in $MAICLI, found $cli_matches" >&2
  exit 1
fi

perl -0pi -e "s/private static let version = \"[^\"]*\"/private static let version = \"$new_version\"/" "$MAICLI"

perl -0pi -e "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $new_version;/g" "$PBXPROJ"

current_build=$(awk -F'= ' '
  /CURRENT_PROJECT_VERSION = / {
    gsub(/;[[:space:]]*$/, "", $2)
    print $2
    exit
  }
' "$PBXPROJ")
new_build=$((current_build + 1))

perl -0pi -e "s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $new_build;/g" "$PBXPROJ"

printf 'version: %s -> %s\n' "$current_version" "$new_version"
printf 'cli:     %s -> %s\n' "$cli_version" "$new_version"
printf 'build:   %s -> %s\n' "$current_build" "$new_build"
