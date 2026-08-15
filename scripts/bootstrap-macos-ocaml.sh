#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
apple_toolchain_root=${LOGSEQ_CHAT_APPLE_TOOLCHAIN_ROOT:-$repo_root/_build/apple-toolchains}
ocaml_version=${LOGSEQ_CHAT_MACOS_OCAML_VERSION:-5.5.0}
deployment_target=${LOGSEQ_CHAT_MACOS_DEPLOYMENT_TARGET:-14.0}
jobs=${LOGSEQ_CHAT_MACOS_BUILD_JOBS:-8}
toolchain_name="host-$ocaml_version-macos$deployment_target"
toolchain_root="$apple_toolchain_root/macos"
target_prefix="$toolchain_root/$toolchain_name"
source_dir="$toolchain_root/ocaml-$ocaml_version-macos$deployment_target"
completion_stamp="$target_prefix/.logseq-chat-toolchain-complete"

die() {
  echo "error: $*" >&2
  exit 1
}

[[ $(uname -s) == Darwin ]] || die "the macOS OCaml toolchain requires macOS"
command -v xcrun >/dev/null 2>&1 || die "xcrun was not found"

if [[ ! -f $completion_stamp ]]; then
  mkdir -p "$toolchain_root"
  if [[ ! -d $source_dir/.git ]]; then
    git clone --depth 1 --branch "$ocaml_version" \
      https://github.com/ocaml/ocaml.git \
      "$source_dir"
  fi

  if [[ ! -f $source_dir/Makefile.config ]]; then
    clang=$(xcrun --sdk macosx --find clang)
    sdk_path=$(xcrun --sdk macosx --show-sdk-path)
    export MACOSX_DEPLOYMENT_TARGET="$deployment_target"
    (
      cd "$source_dir"
      ./configure \
        --disable-ocamldoc \
        --disable-ocamltest \
        --disable-stdlib-manpages \
        --without-zstd \
        --prefix="$target_prefix" \
        CC="$clang -isysroot $sdk_path -mmacosx-version-min=$deployment_target"
    )
  fi

  make -C "$source_dir" -j"$jobs"
  make -C "$source_dir" install
  touch "$completion_stamp"
fi

actual_version=$($target_prefix/bin/ocamlopt.opt -version)
[[ $actual_version == "$ocaml_version" ]] \
  || die "OCaml compiler version is $actual_version, expected $ocaml_version"

echo "$target_prefix"
