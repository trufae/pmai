#!/bin/sh
set -eu
app_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
framework_dir="$app_dir/.deps/AndroidSwiftUI"
revision=e12fb09a906921506a84287f53117ccbf4357102
if [ ! -d "$framework_dir/.git" ]; then
  mkdir -p "$app_dir/.deps"
  git clone https://github.com/PureSwift/AndroidSwiftUI.git "$framework_dir"
fi
actual=$(git -C "$framework_dir" rev-parse HEAD)
if [ "$actual" != "$revision" ]; then
  if [ -n "$(git -C "$framework_dir" status --porcelain)" ]; then
    echo "The UI dependency has local changes; refusing to replace them." >&2
    exit 1
  fi
  git -C "$framework_dir" checkout --detach "$revision"
fi
patch_file="$app_dir/patches/compose-input.patch"
if git -C "$framework_dir" apply --reverse --check "$patch_file" 2>/dev/null; then
  : # The pinned Swift-only input acknowledgement fix is already installed.
elif git -C "$framework_dir" apply --check "$patch_file"; then
  git -C "$framework_dir" apply "$patch_file"
else
  echo "Cannot apply the Swift UI input fix; the dependency has overlapping changes." >&2
  exit 1
fi
