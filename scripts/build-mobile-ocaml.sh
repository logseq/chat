#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 TARGET_PREFIX" >&2
  exit 2
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
target_prefix=$(cd "$1" && pwd)
target="_build/mobile/core/logseq_chat_mobile_entry.exe.o"
dune=${DUNE:-dune}
profile=${DUNE_PROFILE:-dev}

[[ -x $target_prefix/bin/ocamlc ]] || {
  echo "error: target OCaml compiler is missing at $target_prefix" >&2
  exit 1
}

env -u OPAM_SWITCH_PREFIX -u OCAMLPATH \
  PATH="$target_prefix/bin:$PATH" "$dune" build \
  --root "$repo_root" \
  --workspace "$repo_root/dune-workspace.mobile" \
  --profile "$profile" \
  "$target"

printf '%s\n' "$repo_root/$target"
