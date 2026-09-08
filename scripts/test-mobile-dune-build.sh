#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
workspace="$repo_root/dune-workspace.mobile"
builder="$repo_root/scripts/build-mobile-ocaml.sh"
core_dune="$repo_root/core/dune"
dune_project="$repo_root/dune-project"
lockfile="$repo_root/logseq_chat.opam.locked"
legacy_builder="$repo_root/scripts/build-mobile-ocaml-deps.sh"
legacy_mldoc_patch="$repo_root/scripts/patches/mldoc-wrapped.patch"

[[ -f $workspace ]] || {
  echo "error: mobile Dune workspace is missing" >&2
  exit 1
}
[[ -x $builder ]] || {
  echo "error: mobile OCaml builder is missing or not executable" >&2
  exit 1
}

[[ ! -e $repo_root/Vendor/mldoc ]] || {
  echo "error: mldoc must come from the pinned Dune dependency, not a submodule" >&2
  exit 1
}
[[ ! -e $legacy_builder && ! -e $legacy_mldoc_patch ]] || {
  echo "error: legacy manual mobile dependency build files must be removed" >&2
  exit 1
}

grep -Fq '(switch 5.5.0)' "$workspace"
grep -Fq '(host mobile_host)' "$workspace"
for context in ios_simulator ios_device android_arm64 android_x86_64 macos_arm64; do
  grep -Fq "(name $context)" "$workspace"
done
grep -Fq '"$dune" build' "$builder"
grep -Fq 'target="_build/$context/core/logseq_chat_mobile_entry.exe.o"' "$builder"
grep -Fq '(modes object)' "$core_dune"

if grep -Eq '\(modes[^)]*(exe|shared_object)' "$core_dune"; then
  echo "error: mobile OCaml must only build the host-linked object" >&2
  exit 1
fi

if grep -Eq 'ocamlopt|\.cmx|output-complete-obj|yojson|melange|mldoc|datascript|curl|git|patch|find|sed|awk' "$builder"; then
  echo "error: mobile OCaml builder contains dependency or linker internals" >&2
  exit 1
fi

if grep -Fq 'OPAM_SWITCH_PREFIX' "$core_dune"; then
  echo "error: mobile Dune rules depend on a local opam installation path" >&2
  exit 1
fi

if grep -Fq '(depends' "$dune_project"; then
  echo "error: OCaml dependencies must be declared only in logseq_chat.opam" >&2
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
