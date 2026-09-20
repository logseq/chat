#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
coverage_dir=$(mktemp -d "${TMPDIR:-/tmp}/logseq-chat-coverage.XXXXXX")
trap 'rm -rf "$coverage_dir"' EXIT

cd "$repo_root"

BISECT_FILE="$coverage_dir/bisect" \
  opam exec --switch=5.5.0 -- \
  dune runtest core --instrument-with bisect_ppx --force

# Tests execute their compiled LG definitions, not the separate core archive.
# Measure only production graph-runtime definitions in that generated module.
# This is generated execution-point coverage, not CLJC source-line coverage.
# Keep the original 75.58% floor; never lower it to land a migration.
opam exec --switch=5.5.0 -- \
  bisect-ppx-report merge "$coverage_dir/merged.coverage" --coverage-path "$coverage_dir"
opam exec --switch=5.5.0 -- ocamlfind ocamlopt -w -24 \
  -package compiler-libs.common -c -o "$coverage_dir/check.cmx" \
  -impl scripts/lg-coverage.ml
opam exec --switch=5.5.0 -- ocamlfind ocamlopt \
  -package compiler-libs.common -linkpkg -o "$coverage_dir/check.exe" \
  "$coverage_dir/check.cmx"
"$coverage_dir/check.exe" \
  _build/default/lg-test/logseq_chat_lui_test.ml \
  lg-test/logseq_chat_lui_test.ml \
  logseq_chat_graph_runtime_ 7558 "$coverage_dir/merged.coverage"
