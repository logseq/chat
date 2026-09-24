#!/usr/bin/env bash

set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

# Builds a static libffi for a mobile target and installs it under PREFIX so
# that ctypes-foreign's pkg-config discovery picks real (non-Apple-SDK)
# headers for the stub compile and the final link resolves -lffi.
#
# usage: build-mobile-libffi.sh HOST_TRIPLE INSTALL_PREFIX CC [CXX]
host_triple=${1:-}
prefix=${2:-}
cc=${3:-}
cxx=${4:-$cc}
[[ -n $host_triple && -n $prefix && -n $cc ]] \
  || die "usage: $0 HOST_TRIPLE INSTALL_PREFIX CC [CXX]"

version=${LOGSEQ_CHAT_LIBFFI_VERSION:-3.4.8}
stamp="$prefix/.libffi-$version-complete"
if [[ -f $stamp && -f $prefix/lib/libffi.a ]]; then
  echo "$prefix"
  exit 0
fi

src_parent="$prefix/src"
src_dir="$src_parent/libffi-$version"
mkdir -p "$src_parent"
if [[ ! -d $src_dir ]]; then
  curl -fsSL \
    "https://github.com/libffi/libffi/releases/download/v$version/libffi-$version.tar.gz" \
    | tar xz -C "$src_parent"
fi

# Build chatter goes to stderr so callers can safely capture only the prefix.
(
  cd "$src_dir"
  [[ -f Makefile ]] && make distclean >&2 || true
  CC="$cc" CXX="$cxx" CFLAGS="-O2 -fPIC" ./configure \
    --host="$host_triple" \
    --prefix="$prefix" \
    --disable-shared \
    --enable-static \
    --disable-multi-os-directory >&2
  make -j"${LOGSEQ_CHAT_BUILD_JOBS:-8}" >&2
  make install >&2
)

touch "$stamp"
echo "$prefix"
