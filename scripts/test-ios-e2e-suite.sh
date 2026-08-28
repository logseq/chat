#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

all_flows=(
  .maestro/ios-capture-responsive.yaml
  .maestro/ios-chat-send-regression.yaml
  .maestro/ios-cold-start-composer.yaml
  .maestro/ios-outliner-mode.yaml
  .maestro/ios-page-outliner-only.yaml
  .maestro/ios-search-status-regression.yaml
  .maestro/sidebar.yaml
  .maestro/ios-outliner-interactions.yaml
  .maestro/ios-outliner-editor-toolbar.yaml
  .maestro/ios-outliner-continuous-editing.yaml
  .maestro/ios-outliner-empty-block-caret.yaml
  .maestro/ios-outliner-fixture-edit-baseline.yaml
  .maestro/ios-invalid-order-bounds-regression.yaml
  .maestro/ios-outliner-selection-toolbar.yaml
  .maestro/ios-outliner-hierarchy-navigation.yaml
  .maestro/ios-node-tag-navigation.yaml
  .maestro/ios-native-header-navigation.yaml
  .maestro/ios-sidebar-node-navigation.yaml
  .maestro/ios-page-share.yaml
  .maestro/ios-page-favorite.yaml
  .maestro/ios-settings-theme-parity.yaml
  .maestro/ios-settings-tabs.yaml
  .maestro/ios-sidebar-page-empty-block-delete.yaml
  .maestro/ios-rich-block-rendering.yaml
  .maestro/ios-outliner-drag.yaml
  .maestro/ios-graphs.yaml
  .maestro/ios-graphs-lifecycle.yaml
  .maestro/ios-sync-graph-create-regression.yaml
)

selector=${1:-${LOGSEQ_CHAT_IOS_E2E_MODULE:-all}}
case $selector in
  all)
    flows=("${all_flows[@]}")
    ;;
  smoke)
    flows=(
      .maestro/ios-capture-responsive.yaml
      .maestro/ios-cold-start-composer.yaml
      .maestro/ios-search-status-regression.yaml
      .maestro/sidebar.yaml
    )
    ;;
  composer)
    flows=(
      .maestro/ios-capture-responsive.yaml
      .maestro/ios-chat-send-regression.yaml
      .maestro/ios-cold-start-composer.yaml
    )
    ;;
  outliner)
    flows=(
      .maestro/ios-outliner-mode.yaml
      .maestro/ios-page-outliner-only.yaml
      .maestro/ios-outliner-interactions.yaml
      .maestro/ios-outliner-editor-toolbar.yaml
      .maestro/ios-outliner-continuous-editing.yaml
      .maestro/ios-outliner-empty-block-caret.yaml
      .maestro/ios-outliner-fixture-edit-baseline.yaml
      .maestro/ios-invalid-order-bounds-regression.yaml
      .maestro/ios-outliner-selection-toolbar.yaml
      .maestro/ios-outliner-hierarchy-navigation.yaml
      .maestro/ios-sidebar-page-empty-block-delete.yaml
      .maestro/ios-outliner-drag.yaml
    )
    ;;
  navigation)
    flows=(
      .maestro/ios-node-tag-navigation.yaml
      .maestro/ios-native-header-navigation.yaml
      .maestro/ios-sidebar-node-navigation.yaml
      .maestro/ios-page-share.yaml
      .maestro/ios-page-favorite.yaml
    )
    ;;
  settings)
    flows=(
      .maestro/ios-settings-theme-parity.yaml
      .maestro/ios-settings-tabs.yaml
    )
    ;;
  content)
    flows=(.maestro/ios-rich-block-rendering.yaml)
    ;;
  graphs)
    flows=(
      .maestro/ios-graphs.yaml
      .maestro/ios-graphs-lifecycle.yaml
      .maestro/ios-sync-graph-create-regression.yaml
    )
    ;;
  --list)
    echo "Modules: all smoke composer outliner navigation settings content graphs"
    printf '%s\n' "${all_flows[@]}"
    exit 0
    ;;
  *.yaml)
    if [[ $selector = /* ]]; then
      flow_path=$selector
    else
      flow_path="$repo_root/$selector"
    fi
    [[ -f $flow_path ]] || {
      echo "error: iOS E2E flow not found: $selector" >&2
      exit 1
    }
    flows=("$selector")
    ;;
  *)
    echo "error: unknown iOS E2E module or flow: $selector" >&2
    echo "run '$0 --list' to see available modules and flows" >&2
    exit 1
    ;;
esac

if [[ ${LOGSEQ_CHAT_IOS_SKIP_BUILD:-0} != 1 ]]; then
  "$repo_root/scripts/build-mobile-ios-simulator.sh" >/dev/null
fi

start_index=${LOGSEQ_CHAT_IOS_E2E_START_INDEX:-0}
if (( start_index < 0 || start_index >= ${#flows[@]} )); then
  echo "error: LOGSEQ_CHAT_IOS_E2E_START_INDEX must be between 0 and $((${#flows[@]} - 1))" >&2
  exit 1
fi

for ((flow_index = start_index; flow_index < ${#flows[@]}; flow_index++)); do
  flow=${flows[$flow_index]}
  echo "==> $flow"
  if [[ $flow == .maestro/ios-page-outliner-only.yaml \
     || $flow == .maestro/ios-invalid-order-bounds-regression.yaml \
     || $flow == .maestro/ios-outliner-empty-block-caret.yaml \
     || $flow == .maestro/ios-outliner-fixture-edit-baseline.yaml \
     || $flow == .maestro/ios-node-tag-navigation.yaml \
     || $flow == .maestro/ios-sidebar-node-navigation.yaml \
     || $flow == .maestro/ios-page-share.yaml \
     || $flow == .maestro/ios-page-favorite.yaml \
     || $flow == .maestro/ios-sidebar-page-empty-block-delete.yaml \
     || $flow == .maestro/ios-rich-block-rendering.yaml ]]; then
    LOGSEQ_CHAT_IOS_SKIP_BUILD=1 \
      LOGSEQ_CHAT_IOS_E2E_SEED_GRAPH=1 \
      LOGSEQ_CHAT_IOS_E2E_FLOW="$flow" \
      "$repo_root/scripts/test-ios-e2e.sh"
  else
    LOGSEQ_CHAT_IOS_SKIP_BUILD=1 \
      LOGSEQ_CHAT_IOS_E2E_FLOW="$flow" \
      "$repo_root/scripts/test-ios-e2e.sh"
  fi
done

echo "iOS Simulator E2E '$selector' passed ($((${#flows[@]} - start_index)) flows)"
