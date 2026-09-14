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

# These exact basis-point floors preserve the coverage of the current feature
# surface. Raise them whenever tests add coverage; never lower them to land code.
awk '
  BEGIN {
    minimum["core/logseq_chat_graph_runtime.ml"] = 7558
    minimum["core/logseq_chat_outliner.ml"] = 9818
    minimum["core/logseq_chat_outliner_effects.ml"] = 8411
    minimum["core/logseq_chat_outliner_state.ml"] = 9423
    minimum["core/logseq_chat_pending_ops.ml"] = 8894
    minimum["core/logseq_chat_pending_projection.ml"] = 8772
    minimum["core/logseq_chat_sync_tx.ml"] = 10000
  }
  $4 in minimum {
    print
    seen[$4] = 1
    actual = int(($1 * 100) + 0.5)
    if (actual < minimum[$4]) {
      printf "error: coverage for %s regressed below %.2f%%\n", \
        $4, minimum[$4] / 100 > "/dev/stderr"
      failed = 1
    }
  }
  END {
    for (file in minimum) {
      if (!(file in seen)) {
        print "error: missing OCaml coverage data for " file > "/dev/stderr"
        failed = 1
      }
    }
    if (failed) exit 1
  }
' <<<"$summary"
