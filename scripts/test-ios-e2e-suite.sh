#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

flows=(
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
  .maestro/ios-outliner-selection-toolbar.yaml
  .maestro/ios-outliner-hierarchy-navigation.yaml
  .maestro/ios-node-tag-navigation.yaml
  .maestro/ios-sidebar-node-navigation.yaml
  .maestro/ios-page-share.yaml
  .maestro/ios-page-favorite.yaml
  .maestro/ios-settings-theme-parity.yaml
  .maestro/ios-sidebar-page-empty-block-delete.yaml
  .maestro/ios-rich-block-rendering.yaml
  .maestro/ios-outliner-drag.yaml
  .maestro/ios-graphs.yaml
  .maestro/ios-graphs-lifecycle.yaml
  .maestro/ios-sync-graph-create-regression.yaml
)

if [[ ${LOGSEQ_CHAT_IOS_SKIP_BUILD:-0} != 1 ]]; then
  "$repo_root/scripts/build-mobile-ios-simulator.sh" >/dev/null
fi

for flow in "${flows[@]}"; do
  echo "==> $flow"
  if [[ $flow == .maestro/ios-node-tag-navigation.yaml \
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

echo "iOS Simulator E2E suite passed (${#flows[@]} flows)"
