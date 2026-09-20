#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
policy="$repo_root/apple/Sources/LogseqChat/OutlinerEditing.swift"
editor="$repo_root/apple/Sources/LogseqChat/OutlinerInlineEditor.swift"

require_text() {
  local file=$1
  local text=$2
  grep -Fq "$text" "$repo_root/$file" || {
    echo "error: $file must contain: $text" >&2
    exit 1
  }
}

require_text "apple/Sources/LogseqChat/OutlinerEditing.swift" \
  "enum AndroidInlineEditorInputPolicy"
require_text "apple/Sources/LogseqChat/OutlinerInlineEditor.swift" \
  ".material3TextField"
require_text "apple/Sources/LogseqChat/OutlinerInlineEditor.swift" \
  "pendingTextChangeJob"
require_text "apple/Sources/LogseqChat/OutlinerInlineEditor.swift" \
  "pendingCaretChangeJob"
require_text "apple/Sources/LogseqChat/OutlinerInlineEditor.swift" \
  "LaunchedEffect(blockID, options.value.text)"
require_text "apple/Sources/LogseqChat/OutlinerInlineEditor.swift" \
  "FocusRequester"
require_text "apple/Sources/LogseqChat/OutlinerInlineEditor.swift" \
  "focusRequester.requestFocus()"
require_text "apple/Sources/LogseqChat/OutlinerInlineEditor.swift" \
  "keyboardController?.show()"
require_text "apple/Sources/LogseqChat/OutlinerInlineEditor.swift" \
  "onPreviewKeyEvent"
require_text "apple/Sources/LogseqChat/OutlinerInlineEditor.swift" \
  "shouldMergeBackward"

echo "ok - Android inline editor keeps local Compose input and handles structural keys"
