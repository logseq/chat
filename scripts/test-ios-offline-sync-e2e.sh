#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
app_id=${LOGSEQ_CHAT_IOS_APP_ID:-com.logseq.chat}
base_url=${LOGSEQ_CHAT_E2E_BASE_URL:-http://127.0.0.1:8787}
offline_base_url=${LOGSEQ_CHAT_E2E_OFFLINE_BASE_URL:-http://127.0.0.1:18787}
graph_name=${LOGSEQ_CHAT_E2E_GRAPH_NAME:?set LOGSEQ_CHAT_E2E_GRAPH_NAME to the cached graph name}
existing_block=${LOGSEQ_CHAT_E2E_EXISTING_BLOCK:?set LOGSEQ_CHAT_E2E_EXISTING_BLOCK to a cached block title}
offline_block=${LOGSEQ_CHAT_E2E_OFFLINE_BLOCK:-"iOS offline $(date +%s)"}

die() {
  echo "error: $*" >&2
  exit 1
}

device=${LOGSEQ_CHAT_IOS_SIMULATOR_UDID:-}
if [[ -z $device ]]; then
  device=$(
    xcrun simctl list devices booted \
      | awk -F'[()]' '/Booted/ { print $2; exit }'
  )
fi
[[ -n $device ]] || die "no booted iOS simulator was found"

maestro_bin=${MAESTRO_BIN:-}
if [[ -z $maestro_bin ]]; then
  if command -v maestro >/dev/null 2>&1; then
    maestro_bin=$(command -v maestro)
  else
    maestro_bin=$(find /opt/homebrew/Cellar/maestro -path '*/bin/maestro' -type f 2>/dev/null | sort -V | tail -1)
  fi
fi
[[ -n $maestro_bin && -x $maestro_bin ]] || die "Maestro CLI is not installed"

app_container=$(xcrun simctl get_app_container "$device" "$app_id" data 2>/dev/null) \
  || die "install and seed the app with an online graph before running the offline E2E"
[[ -f $app_container/Documents/logseq-chat.sqlite ]] \
  || die "the simulator does not contain a seeded Logseq Chat database"
preferences="$app_container/Library/Preferences/$app_id.plist"
graph_id=$(plutil -extract 'logseq\.selectedGraphId' raw "$preferences" 2>/dev/null) \
  || die "the simulator does not have a selected graph"
graph_directory_name=${graph_id//-/%2D}
checkpoint="$app_container/Documents/graphs/$graph_directory_name/sync.checkpoint"
[[ -f $checkpoint ]] || die "the selected graph does not have a sync checkpoint"
cursor_before=$(jq -er '. as $checkpoint | $checkpoint[index("~:applied-server-t") + 1]' "$checkpoint") \
  || die "the selected graph checkpoint does not contain applied-server-t"

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/logseq-chat-offline-sync.XXXXXX")
offline_flow="$temporary_directory/offline.yaml"
reconnect_flow="$temporary_directory/reconnect.yaml"

restore_base_url() {
  xcrun simctl spawn "$device" defaults write "$app_id" logseq.baseURL "$base_url" >/dev/null
  rm -rf "$temporary_directory"
}
trap restore_base_url EXIT

render_flow() {
  local source=$1
  local destination=$2
  sed \
    -e "s|__LOGSEQ_CHAT_E2E_GRAPH_NAME__|$graph_name|g" \
    -e "s|__LOGSEQ_CHAT_E2E_EXISTING_BLOCK__|$existing_block|g" \
    -e "s|__LOGSEQ_CHAT_E2E_OFFLINE_BLOCK__|$offline_block|g" \
    "$source" > "$destination"
}

render_flow "$repo_root/tests/e2e/ios-offline-restart.yaml" "$offline_flow"
render_flow "$repo_root/tests/e2e/ios-offline-reconnect.yaml" "$reconnect_flow"

xcrun simctl terminate "$device" "$app_id" >/dev/null 2>&1 || true
xcrun simctl spawn "$device" defaults write "$app_id" logseq.baseURL "$offline_base_url"
MAESTRO_CLI_NO_ANALYTICS=1 "$maestro_bin" --device "$device" test "$offline_flow"

xcrun simctl spawn "$device" defaults write "$app_id" logseq.baseURL "$base_url"
MAESTRO_CLI_NO_ANALYTICS=1 "$maestro_bin" --device "$device" test "$reconnect_flow"
cursor_after=$(jq -er '. as $checkpoint | $checkpoint[index("~:applied-server-t") + 1]' "$checkpoint") \
  || die "the reconnected graph checkpoint does not contain applied-server-t"
(( cursor_after > cursor_before )) \
  || die "the WebSocket sync cursor did not advance after the offline block was submitted"

echo "$offline_block cursor $cursor_before -> $cursor_after"
