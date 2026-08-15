#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 TARGET_PREFIX TARGET_TRIPLE SDK_PATH DEPENDENCY_STAMP" >&2
  exit 2
fi

target_prefix=$(cd "$1" && pwd)
target_triple=$2
sdk_path=$3
dependency_stamp=$4
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ocamlopt="$target_prefix/bin/ocamlopt.opt"

{
  printf '%s\n' "$target_triple" "$sdk_path"
  "$ocamlopt" -version
  "$ocamlopt" -config
  if [[ -f $dependency_stamp ]]; then
    cat "$dependency_stamp"
  fi
  shasum -a 256 \
    "$repo_root"/core/*.ml \
    "$repo_root"/core/*.c \
    "$repo_root"/core/*.m
} | shasum -a 256 | cut -d ' ' -f 1
