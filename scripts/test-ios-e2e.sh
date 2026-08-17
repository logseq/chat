#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
flow=${LOGSEQ_CHAT_IOS_E2E_FLOW:-.maestro/ios-capture-responsive.yaml}
app_id=${LOGSEQ_CHAT_IOS_APP_ID:-com.logseq.chat}
screenshots_dir="$repo_root/.maestro/screenshots"
username=${LOGSEQ_CHAT_E2E_USERNAME:-e2etest}
password=${LOGSEQ_CHAT_E2E_PASSWORD:-Logseq-e2e}
base_url=${LOGSEQ_CHAT_E2E_BASE_URL:-http://127.0.0.1:8787}
run_id=${LOGSEQ_CHAT_E2E_RUN_ID:-$(date +%s)}

die() {
  echo "error: $*" >&2
  exit 1
}

maestro_bin=${MAESTRO_BIN:-}
if [[ -z $maestro_bin ]]; then
  if command -v maestro >/dev/null 2>&1; then
    maestro_bin=$(command -v maestro)
  else
    maestro_bin=$(find /opt/homebrew/Cellar/maestro -path '*/bin/maestro' -type f 2>/dev/null | sort -V | tail -1)
  fi
fi
[[ -n $maestro_bin && -x $maestro_bin ]] \
  || die "Maestro CLI is not installed. Install it with: brew install mobile-dev-inc/tap/maestro --formula"

device=${LOGSEQ_CHAT_IOS_SIMULATOR_UDID:-}
if [[ -z $device ]]; then
  device=$(
    xcrun simctl list devices booted \
      | awk -F'[()]' '/Booted/ { print $2; exit }'
  )
fi
[[ -n $device ]] || die "no booted iOS simulator was found"

if [[ ${LOGSEQ_CHAT_IOS_SKIP_BUILD:-0} != 1 ]]; then
  "$repo_root/scripts/build-mobile-ios-simulator.sh" >/dev/null
fi
xcrun simctl uninstall "$device" "$app_id" >/dev/null 2>&1 || true
xcrun simctl spawn "$device" defaults delete "$app_id" logseq.baseURL >/dev/null 2>&1 || true
xcrun simctl spawn "$device" defaults delete "$app_id" logseq.composerDraft >/dev/null 2>&1 || true
xcrun simctl spawn "$device" defaults delete "$app_id" logseq.contentMode >/dev/null 2>&1 || true
xcrun simctl install "$device" "$repo_root/.build/LogseqChat.app"
xcrun simctl spawn "$device" defaults write "$app_id" logseq.baseURL "$base_url"

mkdir -p "$screenshots_dir"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/logseq-chat-ios-e2e.XXXXXX")
rendered_flow="$temporary_directory/flow.yaml"
rendered_setup="$temporary_directory/setup.yaml"
rendered_outliner_anchor="$temporary_directory/outliner-anchor.yaml"
trap 'rm -rf "$temporary_directory"' EXIT
if [[ $flow = /* ]]; then
  flow_path=$flow
else
  flow_path="$repo_root/$flow"
fi
sed \
  -e "s|__LOGSEQ_CHAT_E2E_USERNAME__|$username|g" \
  -e "s|__LOGSEQ_CHAT_E2E_PASSWORD__|$password|g" \
  "$repo_root/.maestro/ios-local-graph-setup.yaml" > "$rendered_setup"
sed \
  -e "s|__LOGSEQ_CHAT_E2E_RUN_ID__|$run_id|g" \
  "$repo_root/.maestro/ios-outliner-anchor-setup.yaml" > "$rendered_outliner_anchor"
sed \
  -e "s|__LOGSEQ_CHAT_E2E_USERNAME__|$username|g" \
  -e "s|__LOGSEQ_CHAT_E2E_PASSWORD__|$password|g" \
  -e "s|__LOGSEQ_CHAT_E2E_RUN_ID__|$run_id|g" \
  -e "s|__LOGSEQ_CHAT_E2E_SETUP_FLOW__|$rendered_setup|g" \
  -e "s|__LOGSEQ_CHAT_E2E_OUTLINER_ANCHOR_FLOW__|$rendered_outliner_anchor|g" \
  "$flow_path" > "$rendered_flow"
if [[ ${LOGSEQ_CHAT_IOS_E2E_SEED_GRAPH:-0} == 1 ]]; then
  MAESTRO_CLI_NO_ANALYTICS=1 "$maestro_bin" --device "$device" test "$rendered_setup"
  data_container=$(xcrun simctl get_app_container "$device" "$app_id" data)
  graph_database=$(find "$data_container/Documents/graphs" -name graph.sqlite -type f | head -1)
  [[ -n $graph_database ]] || die "the setup flow did not download a graph database"
  xcrun simctl terminate "$device" "$app_id" >/dev/null 2>&1 || true
  opam exec --switch=5.5.0 -- dune exec core/logseq_chat_e2e_seed.exe -- "$graph_database"
fi
MAESTRO_CLI_NO_ANALYTICS=1 "$maestro_bin" --device "$device" test "$rendered_flow"
xcrun simctl io "$device" screenshot "$screenshots_dir/ios-e2e-final.png" >/dev/null

echo "$screenshots_dir/ios-e2e-final.png"
