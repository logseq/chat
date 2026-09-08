#!/bin/zsh
set -euo pipefail

# Requires a Debug app with a selected graph already cached on the simulator.
# Restart the process without clearing the graph or authentication state.
device="${LOGSEQ_CHAT_IOS_SIMULATOR:-booted}"
bundle_id="${LOGSEQ_CHAT_IOS_BUNDLE_ID:-com.logseq.chat}"
budget_ms="${LOGSEQ_CHAT_JOURNALS_READY_BUDGET_MS:-300}"
launch_log="$(mktemp -t logseq-journals-launch).log"
launch_pid=""

cleanup() {
  if [[ -n "$launch_pid" ]]; then
    kill "$launch_pid" >/dev/null 2>&1 || true
  fi
  rm -f "$launch_log"
}
trap cleanup EXIT

xcrun simctl terminate "$device" "$bundle_id" >/dev/null 2>&1 || true
SIMCTL_CHILD_LOGSEQ_CHAT_TRACE_STARTUP=1 xcrun simctl launch --console-pty "$device" "$bundle_id" >"$launch_log" 2>&1 &
launch_pid="$!"

for _ in {1..100}; do
  if grep -q "LOGSEQ_LAUNCH_METRIC journals_ui_ready_ms=" "$launch_log"; then
    break
  fi
  sleep 0.05
done

metric="$(sed -n 's/.*LOGSEQ_LAUNCH_METRIC journals_ui_ready_ms=\([0-9.]*\).*/\1/p' "$launch_log" | tail -1)"
if [[ -z "$metric" ]]; then
  print -u2 "journals UI ready launch metric was not emitted"
  cat "$launch_log" >&2
  exit 1
fi

for stage in local_load_started catalog_opened graph_configured open_graph_started open_graph_returned; do
  if ! grep -q "LOGSEQ_LAUNCH_METRIC ${stage}_ms=" "$launch_log"; then
    print -u2 "missing launch stage metric: $stage"
    cat "$launch_log" >&2
    exit 1
  fi
done

if ! grep -q "LOGSEQ_LAUNCH_APPLY_METRIC action=openGraph" "$launch_log"; then
  print -u2 "missing openGraph response apply metric"
  cat "$launch_log" >&2
  exit 1
fi

apply_count="$(grep -c 'LOGSEQ_LAUNCH_APPLY_METRIC action=openGraph' "$launch_log")"
if [[ "$apply_count" != 1 ]]; then
  print -u2 "local launch response must be applied once, got $apply_count"
  cat "$launch_log" >&2
  exit 1
fi

grep 'LOGSEQ_.*METRIC' "$launch_log"

awk -v actual="$metric" -v budget="$budget_ms" 'BEGIN {
  if (actual > budget) {
    printf "journals UI ready exceeded budget: %.3fms > %.3fms\n", actual, budget > "/dev/stderr"
    exit 1
  }
  printf "journals UI ready: %.3fms (budget %.3fms)\n", actual, budget
}'
