#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
flow=${LOGSEQ_CHAT_IOS_E2E_FLOW:-.maestro/ios-capture-responsive.yaml}
app_id=${LOGSEQ_CHAT_IOS_APP_ID:-com.logseq.chat}
app_path=${LOGSEQ_CHAT_IOS_APP_PATH:-$repo_root/.build/LogseqChat.app}
screenshots_dir="$repo_root/.maestro/screenshots"
username=${LOGSEQ_CHAT_E2E_USERNAME:-e2etest}
password=${LOGSEQ_CHAT_E2E_PASSWORD:-Logseq-e2e}
e2ee_password=${LOGSEQ_CHAT_E2EE_PASSWORD:-$password}
run_id=${LOGSEQ_CHAT_E2E_RUN_ID:-$(date +%s)}
base_url=${LOGSEQ_CHAT_E2E_BASE_URL:-http://127.0.0.1:8787}
graph_name=${LOGSEQ_CHAT_IOS_E2E_GRAPH_NAME:-sync-$run_id}
fixture_seed_mode=""
case ${flow##*/} in
  ios-native-header-navigation.yaml)
    graph_name=${LOGSEQ_CHAT_IOS_E2E_GRAPH_NAME:-chat-local-e2e-header-$run_id}
    fixture_seed_mode=--header-navigation
    ;;
  ios-capture-responsive.yaml|ios-chat-send-regression.yaml|ios-cold-start-composer.yaml|ios-search-status-regression.yaml)
    graph_name=${LOGSEQ_CHAT_IOS_E2E_GRAPH_NAME:-chat-local-e2e-composer-$run_id}
    fixture_seed_mode=--composer
    ;;
  ios-outliner-mode.yaml|ios-outliner-interactions.yaml|\
  ios-outliner-editor-toolbar.yaml|ios-outliner-continuous-editing.yaml|\
  ios-outliner-autocomplete-completion.yaml|ios-outliner-autocomplete-visual.yaml|\
  ios-outliner-selection-toolbar.yaml|ios-outliner-hierarchy-navigation.yaml|\
  ios-outliner-drag.yaml)
    graph_name=${LOGSEQ_CHAT_IOS_E2E_GRAPH_NAME:-chat-local-e2e-outliner-$run_id}
    fixture_seed_mode=--outliner
    ;;
  ios-page-outliner-only.yaml|ios-outliner-empty-block-caret.yaml|\
  ios-outliner-fixture-edit-baseline.yaml|ios-invalid-order-bounds-regression.yaml|\
  ios-sidebar-page-empty-block-delete.yaml|ios-node-tag-navigation.yaml|\
  ios-sidebar-node-navigation.yaml|ios-page-share.yaml|ios-page-favorite.yaml|\
  ios-rich-block-rendering.yaml)
    graph_name=${LOGSEQ_CHAT_IOS_E2E_GRAPH_NAME:-chat-local-e2e-fixtures-$run_id}
    fixture_seed_mode=--fixture
    ;;
esac

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
xcrun simctl spawn "$device" defaults delete "$app_id" logseq.selectedGraphId >/dev/null 2>&1 || true
xcrun simctl spawn "$device" defaults delete "$app_id" logseq.composerDraft >/dev/null 2>&1 || true
xcrun simctl spawn "$device" defaults delete "$app_id" logseq.contentMode >/dev/null 2>&1 || true
[[ -d $app_path ]] || die "iOS app bundle was not found: $app_path"
xcrun simctl install "$device" "$app_path"
xcrun simctl spawn "$device" defaults write "$app_id" logseq.baseURL "$base_url"

mkdir -p "$screenshots_dir"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/logseq-chat-ios-e2e.XXXXXX")
rendered_flow="$temporary_directory/flow.yaml"
rendered_setup="$temporary_directory/setup.yaml"
rendered_outliner_anchor="$temporary_directory/outliner-anchor.yaml"
rendered_graphs_lifecycle_fixture="$temporary_directory/graphs-lifecycle-fixture.yaml"
trap 'rm -rf "$temporary_directory"' EXIT
if [[ $flow = /* ]]; then
  flow_path=$flow
else
  flow_path="$repo_root/$flow"
fi
sed \
  -e "s|__LOGSEQ_CHAT_E2E_USERNAME__|$username|g" \
  -e "s|__LOGSEQ_CHAT_E2E_PASSWORD__|$password|g" \
  -e "s|__LOGSEQ_CHAT_E2EE_PASSWORD__|$e2ee_password|g" \
  -e "s|__LOGSEQ_CHAT_E2E_GRAPH_NAME__|$graph_name|g" \
  "$repo_root/.maestro/ios-local-graph-setup.yaml" > "$rendered_setup"
sed \
  -e "s|__LOGSEQ_CHAT_E2E_RUN_ID__|$run_id|g" \
  "$repo_root/.maestro/ios-outliner-anchor-setup.yaml" > "$rendered_outliner_anchor"
cp \
  "$repo_root/.maestro/ios-graphs-lifecycle-fixture-setup.yaml" \
  "$rendered_graphs_lifecycle_fixture"
sed \
  -e "s|__LOGSEQ_CHAT_E2E_USERNAME__|$username|g" \
  -e "s|__LOGSEQ_CHAT_E2E_PASSWORD__|$password|g" \
  -e "s|__LOGSEQ_CHAT_E2E_RUN_ID__|$run_id|g" \
  -e "s|__LOGSEQ_CHAT_E2E_SETUP_FLOW__|$rendered_setup|g" \
  -e "s|__LOGSEQ_CHAT_E2E_OUTLINER_ANCHOR_FLOW__|$rendered_outliner_anchor|g" \
  "$flow_path" > "$rendered_flow"
if [[ ${LOGSEQ_CHAT_IOS_E2E_SEED_GRAPH:-0} == 1 || -n $fixture_seed_mode ]]; then
  MAESTRO_CLI_NO_ANALYTICS=1 "$maestro_bin" --device "$device" test "$rendered_setup"
  data_container=$(xcrun simctl get_app_container "$device" "$app_id" data)
  graph_database=""
  for _ in {1..120}; do
    if [[ -d $data_container/Documents/graphs ]]; then
      graph_database=$(find "$data_container/Documents/graphs" -name graph.sqlite -type f | head -1)
    fi
    if [[ -n $graph_database && -f ${graph_database%/graph.sqlite}/sync.checkpoint ]]; then
      break
    fi
    sleep 0.5
  done
  [[ -n $graph_database && -f ${graph_database%/graph.sqlite}/sync.checkpoint ]] \
    || die "timed out waiting for the graph snapshot import to finish"
  xcrun simctl terminate "$device" "$app_id" >/dev/null 2>&1 || true
  if [[ -n $fixture_seed_mode ]]; then
    opam exec --switch=5.5.0 -- \
      dune exec core/logseq_chat_e2e_seed.exe -- "$graph_database" "$fixture_seed_mode"
  else
    opam exec --switch=5.5.0 -- dune exec core/logseq_chat_e2e_seed.exe -- "$graph_database"
  fi
fi
if [[ ${flow##*/} == ios-graphs-lifecycle.yaml ]]; then
  MAESTRO_CLI_NO_ANALYTICS=1 "$maestro_bin" --device "$device" test "$rendered_setup"
  MAESTRO_CLI_NO_ANALYTICS=1 \
    "$maestro_bin" --device "$device" test "$rendered_graphs_lifecycle_fixture"
fi
MAESTRO_CLI_NO_ANALYTICS=1 "$maestro_bin" --device "$device" test "$rendered_flow"
xcrun simctl io "$device" screenshot "$screenshots_dir/ios-e2e-final.png" >/dev/null

echo "$screenshots_dir/ios-e2e-final.png"
