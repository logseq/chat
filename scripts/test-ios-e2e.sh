#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
flow=${LOGSEQ_CHAT_IOS_E2E_FLOW:-.maestro/ios-capture-responsive.yaml}
app_id=${LOGSEQ_CHAT_IOS_APP_ID:-com.logseq.chat}
screenshots_dir="$repo_root/.maestro/screenshots"
pat=${LOGSEQ_CHAT_E2E_PAT:-logseq_pat_e2e_invalid}

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

"$repo_root/scripts/build-mobile-ios-simulator.sh" >/dev/null
xcrun simctl uninstall "$device" "$app_id" >/dev/null 2>&1 || true
xcrun simctl spawn "$device" defaults delete "$app_id" logseq.baseURL >/dev/null 2>&1 || true
xcrun simctl spawn "$device" defaults delete "$app_id" logseq.token >/dev/null 2>&1 || true
xcrun simctl spawn "$device" defaults delete "$app_id" logseq.composerDraft >/dev/null 2>&1 || true
xcrun simctl install "$device" "$repo_root/.build/LogseqChat.app"
if [[ $pat != "logseq_pat_e2e_invalid" ]]; then
  xcrun simctl spawn "$device" defaults write "$app_id" logseq.baseURL "https://api-staging.logseq.io"
  xcrun simctl spawn "$device" defaults write "$app_id" logseq.token "$pat"
fi

mkdir -p "$screenshots_dir"
rendered_flow=$(mktemp "${TMPDIR:-/tmp}/logseq-chat-ios-e2e.XXXXXX.yaml")
trap 'rm -f "$rendered_flow"' EXIT
sed "s|__LOGSEQ_CHAT_E2E_PAT__|$pat|g" "$repo_root/$flow" > "$rendered_flow"
MAESTRO_CLI_NO_ANALYTICS=1 "$maestro_bin" --device "$device" test "$rendered_flow"
xcrun simctl io "$device" screenshot "$screenshots_dir/ios-e2e-final.png" >/dev/null

echo "$screenshots_dir/ios-e2e-final.png"
