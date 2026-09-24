#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 TARGET_PREFIX DUNE_CONTEXT" >&2
  exit 2
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
target_prefix=$(cd "$1" && pwd)
context=$2
target="_build/$context/shared/native/logseq_chat_mobile_entry.exe.o"
# Local opam switches (e.g. CI's _opam) are addressed by their parent dir, not
# by name — the checked-in workspace pins the named `5.5.0` switch.
switch=${LOGSEQ_CHAT_OPAM_SWITCH:-}
if [[ -z $switch ]] && command -v opam >/dev/null 2>&1; then
  switch=$(opam switch show 2>/dev/null || true)
fi

if [[ -n ${DUNE:-} ]]; then
  dune=$DUNE
elif command -v dune >/dev/null 2>&1; then
  dune=$(command -v dune)
elif command -v opam >/dev/null 2>&1 && [[ -n $switch ]]; then
  dune=$(opam exec --switch="$switch" -- which dune)
elif command -v opam >/dev/null 2>&1; then
  dune=$(opam exec --switch=5.5.0 -- which dune)
else
  echo "error: dune not found on PATH and opam is unavailable" >&2
  exit 1
fi
profile=${DUNE_PROFILE:-dev}
workspace="$repo_root/dune-workspace.mobile"
if [[ -n $switch ]]; then
  workspace="$repo_root/_build/dune-workspace.mobile"
  mkdir -p "$(dirname "$workspace")"
  sed "s|(switch [^)]*)|(switch $switch)|" \
    "$repo_root/dune-workspace.mobile" > "$workspace"
fi

echo "build-mobile-ocaml: dune=$dune workspace=$workspace" >&2

[[ -x $target_prefix/bin/ocamlc ]] || {
  echo "error: target OCaml compiler is missing at $target_prefix" >&2
  exit 1
}

env -u OPAM_SWITCH_PREFIX -u OCAMLPATH \
  PATH="$target_prefix/bin:$PATH" "$dune" build \
  --root "$repo_root" \
  --workspace "$workspace" \
  --profile "$profile" \
  "$target"

printf '%s\n' "$repo_root/$target"
