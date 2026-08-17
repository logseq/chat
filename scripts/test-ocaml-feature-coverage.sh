#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
coverage_dir=$(mktemp -d "${TMPDIR:-/tmp}/logseq-chat-coverage.XXXXXX")
trap 'rm -rf "$coverage_dir"' EXIT

cd "$repo_root"

BISECT_FILE="$coverage_dir/bisect" \
  opam exec --switch=5.5.0 -- \
  dune runtest core --instrument-with bisect_ppx --force

summary=$(
  opam exec --switch=5.5.0 -- \
    bisect-ppx-report summary --coverage-path "$coverage_dir" --per-file
)

awk '
  BEGIN {
    expected["core/logseq_chat_fractional_order.ml"] = 1
    expected["core/logseq_chat_graph_runtime.ml"] = 1
    expected["core/logseq_chat_outliner.ml"] = 1
    expected["core/logseq_chat_outliner_effects.ml"] = 1
    expected["core/logseq_chat_outliner_state.ml"] = 1
    expected["core/logseq_chat_pending_ops.ml"] = 1
    expected["core/logseq_chat_pending_projection.ml"] = 1
    expected["core/logseq_chat_sync_tx.ml"] = 1
  }
  $4 in expected {
    print
    seen[$4] = 1
    if ($1 != "100.00") failed = 1
  }
  END {
    for (file in expected) {
      if (!(file in seen)) {
        print "error: missing OCaml coverage data for " file > "/dev/stderr"
        failed = 1
      }
    }
    if (failed) exit 1
  }
' <<<"$summary"
