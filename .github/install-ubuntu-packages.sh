#!/usr/bin/env bash
set -euo pipefail

# Limit APT to Ubuntu packages so unrelated runner repositories cannot block CI.
sources=/etc/apt/sources.list.d/ubuntu.sources
apt=(apt-get -o Dir::Etc::sourceparts=- -o Acquire::Retries=0
  -o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15)

install_packages() {
  local source_file=$1
  shift
  "${apt[@]}" -o Dir::Etc::sourcelist="$source_file" update --error-on=any --no-list-cleanup &&
    "${apt[@]}" -o Dir::Etc::sourcelist="$source_file" install -y --no-install-recommends "$@"
}

if install_packages "$sources" "$@"; then
  exit 0
fi

mirror=https://ftp.fau.de/ubuntu
if grep -q '^URIs:.*/ubuntu-ports' "$sources"; then
  mirror+=-ports
fi
echo "Retrying Ubuntu package installation via $mirror" >&2
fallback=$(mktemp --suffix=.sources)
trap 'rm -f "$fallback"' EXIT
# Preserve the runner's suites, components and Ubuntu archive signing key.
sed "s|^URIs:.*|URIs: $mirror|" "$sources" > "$fallback"
install_packages "$fallback" "$@"
