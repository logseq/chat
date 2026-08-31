#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
control_source="$(rtk sed -n '/^(defui main-header-leading /,/^(defui main-header-title /p' \
  "${repo_root}/lg/logseq_chat/view.cljc")"
if printf '%s\n' "${control_source}" | rtk rg -q ':corner-radius'; then
  echo "main-header-leading overrides the native toolbar button shape" >&2
  exit 1
fi
if printf '%s\n' "${control_source}" \
  | rtk rg -q ':(width|height)[[:space:]]+[0-9]'; then
  echo "main-header-leading overrides the native toolbar control size" >&2
  exit 1
fi

simulator_udid="${LOGSEQ_CHAT_IOS_SIMULATOR_UDID:-}"
if [[ -z "${simulator_udid}" ]]; then
  echo "LOGSEQ_CHAT_IOS_SIMULATOR_UDID is required" >&2
  exit 2
fi

hierarchy="$(maestro --udid "${simulator_udid}" hierarchy 2>/dev/null)"
bounds="$({ printf '%s\n' "${hierarchy}" | sed -n '/^{/,$p' | jq -r '
  .. | objects
  | select(.attributes?["resource-id"] == "button.sidebar")
  | .attributes.bounds
'; } | head -n 1)"

if [[ ! "${bounds}" =~ ^\[(-?[0-9]+),(-?[0-9]+)\]\[(-?[0-9]+),(-?[0-9]+)\]$ ]]; then
  echo "Unable to read button.sidebar bounds: ${bounds}" >&2
  exit 2
fi

width=$((BASH_REMATCH[3] - BASH_REMATCH[1]))
height=$((BASH_REMATCH[4] - BASH_REMATCH[2]))
if [[ "${width}" -ne "${height}" ]]; then
  echo "button.sidebar is not circular: ${width}x${height} (${bounds})" >&2
  exit 1
fi

echo "button.sidebar uses a square circular-control frame: ${width}x${height}"
