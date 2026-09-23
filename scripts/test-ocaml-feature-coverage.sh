#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
coverage_dir=$(mktemp -d "${TMPDIR:-/tmp}/logseq-chat-coverage.XXXXXX")
trap 'rm -rf "$coverage_dir"' EXIT

cd "$repo_root"

BISECT_FILE="$coverage_dir/bisect" \
  opam exec --switch=5.5.0 -- \
  dune runtest shared/native --instrument-with bisect_ppx --force

# Tests exercise the production graph-runtime module through the ported test
# suite; measure only its top-level definitions. This is execution-point
# coverage, not source-line coverage. Keep the original 75.58% floor; never
# lower it to land a migration.
opam exec --switch=5.5.0 -- \
  bisect-ppx-report merge "$coverage_dir/merged.coverage" --coverage-path "$coverage_dir"
opam exec --switch=5.5.0 -- ocamlfind ocamlopt -w -24 \
  -package compiler-libs.common -c -o "$coverage_dir/check.cmx" \
  -impl scripts/coverage_check.ml
opam exec --switch=5.5.0 -- ocamlfind ocamlopt \
  -package compiler-libs.common -linkpkg -o "$coverage_dir/check.exe" \
  "$coverage_dir/check.cmx"
"$coverage_dir/check.exe" \
  shared/src/logseq_chat/core/graph_runtime.ml \
  shared/src/logseq_chat/core/graph_runtime.ml \
  "" 7558 "$coverage_dir/merged.coverage"
