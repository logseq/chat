#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
policy="$repo_root/Sources/LogseqChat/OutlinerEditing.swift"
editor="$repo_root/Sources/LogseqChat/OutlinerInlineEditor.swift"

require_text() {
  local file=$1
  local text=$2
  grep -Fq "$text" "$repo_root/$file" || {
    echo "error: $file must contain: $text" >&2
    exit 1
  }
}

require_text "Sources/LogseqChat/OutlinerEditing.swift" \
  "enum AndroidInlineEditorInputPolicy"
require_text "Sources/LogseqChat/OutlinerInlineEditor.swift" \
  ".material3TextField"
require_text "Sources/LogseqChat/OutlinerInlineEditor.swift" \
  "pendingTextChangeJob"
require_text "Sources/LogseqChat/OutlinerInlineEditor.swift" \
  "pendingCaretChangeJob"
require_text "Sources/LogseqChat/OutlinerInlineEditor.swift" \
  "LaunchedEffect(blockID, options.value.text)"
require_text "Sources/LogseqChat/OutlinerInlineEditor.swift" \
  "onPreviewKeyEvent"
require_text "Sources/LogseqChat/OutlinerInlineEditor.swift" \
  "shouldMergeBackward"

echo "ok - Android inline editor keeps local Compose input and handles structural keys"
