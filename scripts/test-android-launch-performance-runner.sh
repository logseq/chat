#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
runner="$repo_root/scripts/test-android-launch-performance.sh"
mock_bin=$(mktemp -d "${TMPDIR:-/tmp}/logseq-chat-android-launch-bin.XXXXXX")
failure_output=$(mktemp "${TMPDIR:-/tmp}/logseq-chat-android-launch-failure.XXXXXX")
trap 'rm -rf "$mock_bin"; rm -f "$failure_output"' EXIT

cat >"$mock_bin/adb" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"shell am start -W -S"*)
    printf '%s\n' 'Status: ok' 'LaunchState: COLD' 'TotalTime: 842' 'Complete'
    ;;
  *"logcat -d -v brief"*)
    printf '%s\n' \
      'I/System.out: LOGSEQ_LAUNCH_METRIC authentication_published_ms=402.000' \
      'I/System.out: LOGSEQ_LAUNCH_METRIC first_ui_rendered_ms=404.000'
    ;;
esac
EOF
chmod +x "$mock_bin/adb"

PATH="$mock_bin:$PATH" ANDROID_SERIAL=test-device "$runner" >/dev/null

if PATH="$mock_bin:$PATH" \
  ANDROID_SERIAL=test-device \
  LOGSEQ_CHAT_ANDROID_TOTAL_TIME_BUDGET_MS=800 \
  "$runner" >"$failure_output" 2>&1; then
  echo "error: Android launch gate accepted a launch above budget" >&2
  exit 1
fi
grep -Fq "Android cold launch exceeded budget" "$failure_output" \
  || { echo "error: Android launch gate did not explain the budget failure" >&2; exit 1; }

echo "Android launch performance runner tests passed"
