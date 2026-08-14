#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_flow="$repo_root/.maestro/ios-local-realtime-sync.yaml"
username=${LOGSEQ_CHAT_E2E_USERNAME:-e2etest}
password=${LOGSEQ_CHAT_E2E_PASSWORD:-Logseq-e2e}
graph_name=${LOGSEQ_CHAT_E2E_GRAPH_NAME:?set LOGSEQ_CHAT_E2E_GRAPH_NAME to the graph created by the desktop test}
desktop_block=${LOGSEQ_CHAT_E2E_DESKTOP_BLOCK:?set LOGSEQ_CHAT_E2E_DESKTOP_BLOCK to the block created by the desktop test}
mobile_block=${LOGSEQ_CHAT_E2E_MOBILE_BLOCK:-"Mobile SSE $(date +%s)"}

rendered_flow=$(mktemp "${TMPDIR:-/tmp}/logseq-chat-local-sync.XXXXXX.yaml")
trap 'rm -f "$rendered_flow"' EXIT

sed \
  -e "s|__LOGSEQ_CHAT_E2E_USERNAME__|$username|g" \
  -e "s|__LOGSEQ_CHAT_E2E_PASSWORD__|$password|g" \
  -e "s|__LOGSEQ_CHAT_E2E_GRAPH_NAME__|$graph_name|g" \
  -e "s|__LOGSEQ_CHAT_E2E_DESKTOP_BLOCK__|$desktop_block|g" \
  -e "s|__LOGSEQ_CHAT_E2E_MOBILE_BLOCK__|$mobile_block|g" \
  "$source_flow" > "$rendered_flow"

LOGSEQ_CHAT_IOS_E2E_FLOW=$rendered_flow \
  "$repo_root/scripts/test-ios-e2e.sh"
