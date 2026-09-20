#!/bin/sh
# Install the latest pmai CLI release without administrator privileges.

set -eu

repository="trufae/pmai"
version="${PMAI_VERSION:-latest}"
install_dir="${PMAI_INSTALL_DIR:-}"

say() {
  printf '%s\n' "pmai: $*"
}

die() {
  printf '%s\n' "pmai: error: $*" >&2
  exit 1
}

has() {
  command -v "$1" >/dev/null 2>&1
}

path_contains() {
  candidate=$1
  old_ifs=$IFS
  IFS=:
  for path_entry in ${PATH:-}; do
    IFS=$old_ifs
    [ "$path_entry" = "$candidate" ] && return 0
  done
  IFS=$old_ifs
  return 1
}

detect_platform() {
  kernel=$(uname -s 2>/dev/null || true)
  if [ -n "${ANDROID_ROOT:-}" ] || [ -n "${ANDROID_DATA:-}" ] || [ -n "${TERMUX_VERSION:-}" ]; then
    platform=android
  else
    case "$kernel" in
      Darwin) platform=macos ;;
      Linux) platform=linux ;;
      *) die "unsupported operating system: ${kernel:-unknown}" ;;
    esac
  fi

  machine=$(uname -m 2>/dev/null || true)
  case "$machine" in
    x86_64|amd64) architecture=x64 ;;
    arm64|aarch64|armv8*) architecture=arm64 ;;
    *) die "unsupported CPU architecture: ${machine:-unknown}" ;;
  esac

  if [ "$platform" = android ] && [ "$architecture" != arm64 ]; then
    die "Android releases currently support arm64 devices"
  fi

  # The regular Linux build links against glibc. Musl distributions such as
  # Alpine get the fully static build, which also runs on glibc systems too
  # old for the regular one; PMAI_LIBC=musl or PMAI_LIBC=glibc forces either.
  libc=""
  if [ "$platform" = linux ]; then
    case "${PMAI_LIBC:-}" in
      musl) libc=musl ;;
      glibc | gnu) ;;
      "")
        if [ -e "/lib/ld-musl-$machine.so.1" ] || ldd --version 2>&1 | grep -qi musl; then
          libc=musl
        fi
        ;;
      *) die "PMAI_LIBC must be musl or glibc" ;;
    esac
  fi
}

choose_install_dir() {
  if [ -n "$install_dir" ]; then
    return
  fi

  existing=$(command -v pmai || true)
  if [ -n "$existing" ] && [ -f "$existing" ]; then
    install_dir=$(CDPATH= cd "$(dirname "$existing")" && pwd)
    return
  fi

  preferred="${HOME:?HOME is not set}/.local/bin"
  if path_contains "$preferred"; then
    install_dir=$preferred
    return
  fi

  home_bin="$HOME/bin"
  if path_contains "$home_bin"; then
    install_dir=$home_bin
    return
  fi

  old_ifs=$IFS
  IFS=:
  for path_entry in ${PATH:-}; do
    IFS=$old_ifs
    case "$path_entry" in
      ""|.|/bin|/sbin|/usr/bin|/usr/sbin) ;;
      /*)
        if [ -d "$path_entry" ] && [ -w "$path_entry" ]; then
          install_dir=$path_entry
          return
        fi
        ;;
    esac
  done
  IFS=$old_ifs

  install_dir=$preferred
}

sha256_file() {
  file=$1
  if has sha256sum; then
    sha256sum "$file" | awk '{print $1}'
  elif has shasum; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif has openssl; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
  else
    die "a SHA-256 tool is required (sha256sum, shasum, or openssl)"
  fi
}

extract_archive() {
  archive=$1
  destination=$2
  if has unzip; then
    unzip -q "$archive" -d "$destination"
  elif has busybox && busybox unzip -h >/dev/null 2>&1; then
    busybox unzip -q "$archive" -d "$destination"
  elif has python3; then
    python3 -m zipfile -e "$archive" "$destination"
  else
    die "unzip is required to unpack the pmai release"
  fi
}

detect_platform
choose_install_dir
has curl || die "curl is required"

if [ "$version" = latest ]; then
  release_url=$(curl -fsSLI --retry 2 --connect-timeout 15 -o /dev/null -w '%{url_effective}' \
    "https://github.com/$repository/releases/latest") || die "could not check the latest release"
  case "$release_url" in
    "https://github.com/$repository/releases/tag/"*) version=${release_url##*/} ;;
    *) die "could not determine the latest release version" ;;
  esac
fi

case "$version" in
  ""|*[!A-Za-z0-9._-]*) die "PMAI_VERSION contains unsupported characters" ;;
  *) release_base="https://github.com/$repository/releases/download/$version" ;;
esac
release_base="${PMAI_RELEASE_BASE:-$release_base}"

target="$install_dir/pmai"
current_version=$("$target" --version 2>/dev/null || true)
if [ -n "$current_version" ] && [ "${current_version#v}" = "${version#v}" ]; then
  say "No updates available (pmai $current_version)."
  exit 0
fi
mkdir -p "$install_dir" || die "cannot create install directory: $install_dir"
[ -w "$install_dir" ] || die "install directory is not writable: $install_dir"

asset="pmai-$platform-$architecture${libc:+-$libc}.zip"
if [ "$platform" = macos ]; then
  asset_fallback="pmai-macos-universal.zip"
else
  asset_fallback=""
fi

temp_root=${TMPDIR:-/tmp}
temp_dir=$(mktemp -d "$temp_root/pmai-install.XXXXXX") || die "could not create a temporary directory"
cleanup() {
  rm -rf "$temp_dir"
}
trap cleanup EXIT HUP INT TERM

archive="$temp_dir/$asset"
say "downloading $asset"
if ! curl -fL --retry 2 --connect-timeout 15 "$release_base/$asset" -o "$archive"; then
  if [ -n "$asset_fallback" ]; then
    asset=$asset_fallback
    archive="$temp_dir/$asset"
    say "trying universal macOS release"
    curl -fL --retry 2 --connect-timeout 15 "$release_base/$asset" -o "$archive" ||
      die "no compatible release asset was found"
  else
    die "no compatible release asset was found"
  fi
fi

checksums="$temp_dir/SHA256SUMS"
curl -fL --retry 2 --connect-timeout 15 "$release_base/SHA256SUMS" -o "$checksums" ||
  die "the release checksum file is missing"
expected=$(awk -v file="$asset" '$2 == file || $2 == "*" file { print $1; exit }' "$checksums")
[ -n "$expected" ] || die "no checksum was published for $asset"
actual=$(sha256_file "$archive")
[ "$actual" = "$expected" ] || die "checksum verification failed for $asset"
say "checksum verified"

payload="$temp_dir/payload"
mkdir -p "$payload"
extract_archive "$archive" "$payload" || die "could not unpack $asset"
binary=$(find "$payload" -type f -name pmai -print | head -n 1)
[ -n "$binary" ] || die "the release archive does not contain pmai"

if [ "$platform" = android ]; then
  runtime=$(find "$payload" -type f -name 'libc++_shared.so' -print | head -n 1)
  [ -n "$runtime" ] || die "the Android release is missing libc++_shared.so"

  real_target="$install_dir/pmai-android"
  runtime_target="$install_dir/libc++_shared.so"
  cp "$binary" "$real_target.new"
  cp "$runtime" "$runtime_target.new"
  chmod 755 "$real_target.new"
  chmod 644 "$runtime_target.new"
  mv -f "$real_target.new" "$real_target"
  mv -f "$runtime_target.new" "$runtime_target"

  wrapper="$target.new"
  printf '%s\n' \
    '#!/bin/sh' \
    'pmai_bindir=$(CDPATH= cd "$(dirname "$0")" && pwd)' \
    'LD_LIBRARY_PATH="$pmai_bindir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"' \
    'export LD_LIBRARY_PATH' \
    'exec "$pmai_bindir/pmai-android" "$@"' > "$wrapper"
  chmod 755 "$wrapper"
  mv -f "$wrapper" "$target"
else
  cp "$binary" "$target.new"
  chmod 755 "$target.new"
  mv -f "$target.new" "$target"
fi

"$target" --help >/dev/null 2>&1 || die "pmai was installed but failed its startup check"
say "installed $platform/$architecture${libc:+ ($libc)} to $target"

if path_contains "$install_dir"; then
  say "ready — run: pmai"
else
  say "$install_dir is not currently on PATH"
  say "add this to your shell profile: export PATH=\"$install_dir:\$PATH\""
fi
