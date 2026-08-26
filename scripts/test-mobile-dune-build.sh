#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
workspace="$repo_root/dune-workspace.mobile"
builder="$repo_root/scripts/build-mobile-ocaml.sh"
core_dune="$repo_root/core/dune"
lockfile="$repo_root/logseq_chat.opam.locked"

[[ -f $workspace ]] || {
  echo "error: mobile Dune workspace is missing" >&2
  exit 1
}
[[ -x $builder ]] || {
  echo "error: mobile OCaml builder is missing or not executable" >&2
  exit 1
}

grep -Fq '(switch 5.5.0)' "$workspace"
grep -Fq '(host mobile_host)' "$workspace"
grep -Fq '"$dune" build' "$builder"

if grep -Eq 'ocamlopt|\.cmx|output-complete-obj|yojson|melange|mldoc|datascript|opam|curl|git|patch|find|sed|awk' "$builder"; then
  echo "error: mobile OCaml builder contains dependency or linker internals" >&2
  exit 1
fi

if grep -Fq 'OPAM_SWITCH_PREFIX' "$core_dune"; then
  echo "error: mobile Dune rules depend on a local opam installation path" >&2
  exit 1
fi

if [[ -f $lockfile ]] && grep -Fq 'file:///' "$lockfile"; then
  echo "error: mobile dependency lock contains a local file URL" >&2
  exit 1
fi

line_count=$(wc -l <"$builder")
((line_count <= 40)) || {
  echo "error: mobile OCaml builder is too large: $line_count lines" >&2
  exit 1
}

echo "ok - mobile OCaml build is a thin Dune wrapper"
