#!/usr/bin/env bash
# Build Ubuntu's patched libxml2 without its large optional ICU dependency.
set -euo pipefail

mkdir -p "$1"
output_dir=$(cd "$1" && pwd)
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT

cd "$build_dir"
apt-get source --only-source libxml2
cd libxml2-*/
autoreconf -fi
./configure --disable-shared --enable-static --disable-maintainer-mode \
  --without-icu --with-iconv --without-python --with-zlib --with-lzma CFLAGS=-Os
make -j2 libxml2.la
cp .libs/libxml2.a "$output_dir/libxml2.a"

# FoundationXML's -lxml2 finds this script before the system shared library.
printf 'GROUP ( "%s/libxml2.a" -lz -llzma -lm )\n' "$output_dir" > "$output_dir/libxml2.so"
