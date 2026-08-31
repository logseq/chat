#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
app_id=com.logseq.chat
signed_out_flow=.maestro/android-signed-out.yaml
connect_flow=.maestro/android-staging-connect.yaml
capture_flow=.maestro/android-capture-search.yaml
autocomplete_flow=.maestro/android-outliner-autocomplete-completion.yaml
navigation_flow=.maestro/android-material-navigation.yaml
graphs_flow=.maestro/android-graphs.yaml

die() {
  echo "error: $*" >&2
  exit 1
}

selector=${1:-${LOGSEQ_CHAT_ANDROID_E2E_MODULE:-all}}
case $selector in
  all)
    flows=(
      "$signed_out_flow"
      "$connect_flow"
      "$capture_flow"
      "$autocomplete_flow"
      "$navigation_flow"
      "$graphs_flow"
    )
    needs_connection=1
    needs_clear_state=1
    needs_primary_button=1
    ;;
  signed-out)
    flows=("$signed_out_flow")
    needs_connection=0
    needs_clear_state=1
    needs_primary_button=1
    ;;
  connect)
    flows=("$connect_flow")
    needs_connection=1
    needs_clear_state=1
    needs_primary_button=0
    ;;
  capture)
    flows=("$capture_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  autocomplete)
    flows=("$autocomplete_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  navigation)
    flows=("$navigation_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  graphs)
    flows=("$graphs_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  --list)
    echo "Modules: all signed-out connect capture autocomplete navigation graphs"
    printf '%s\n' \
      "$signed_out_flow" \
      "$connect_flow" \
      "$capture_flow" \
      "$autocomplete_flow" \
      "$navigation_flow" \
      "$graphs_flow"
    exit 0
    ;;
  *.yaml)
    if [[ $selector = /* ]]; then
      flow_path=$selector
    else
      flow_path="$repo_root/$selector"
    fi
    [[ -f $flow_path ]] || die "Android E2E flow not found: $selector"
    flows=("$selector")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  *)
    die "unknown Android E2E module or flow: $selector"
    ;;
esac

if (( needs_connection )); then
  : "${LOGSEQ_CHAT_E2E_USERNAME:?error: LOGSEQ_CHAT_E2E_USERNAME is required}"
  : "${LOGSEQ_CHAT_E2E_PASSWORD:?error: LOGSEQ_CHAT_E2E_PASSWORD is required}"
  : "${LOGSEQ_CHAT_E2E_BASE_URL:?error: LOGSEQ_CHAT_E2E_BASE_URL is required}"
fi

command -v adb >/dev/null 2>&1 || die "adb is not installed"
command -v maestro >/dev/null 2>&1 || die "Maestro CLI is not installed"
command -v gradle >/dev/null 2>&1 || die "Gradle is not installed"

temporary_files=()
cleanup() {
  if (( ${#temporary_files[@]} > 0 )); then
    rm -f "${temporary_files[@]}"
  fi
}
trap cleanup EXIT

device=${ANDROID_SERIAL:-}
if [[ -z $device ]]; then
  device=$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')
fi
[[ -n $device ]] || die "no online Android emulator or device was found"

if [[ ${LOGSEQ_CHAT_ANDROID_E2E_SKIP_BUILD:-0} != 1 ]]; then
  ANDROID_SERIAL=$device gradle --project-dir "$repo_root/Android" :app:assembleDebug
fi

if [[ ${LOGSEQ_CHAT_ANDROID_E2E_SKIP_INSTALL:-0} != 1 ]]; then
  apk="$repo_root/.build/Android/app/outputs/apk/debug/app-debug.apk"
  [[ -f $apk ]] || die "Android debug APK was not produced at $apk"
  adb -s "$device" install -r "$apk" >/dev/null
fi

if (( needs_clear_state )) && [[ ${LOGSEQ_CHAT_ANDROID_E2E_CLEAR_STATE:-1} == 1 ]]; then
  adb -s "$device" shell pm clear "$app_id" >/dev/null
fi

if (( needs_primary_button )); then
  ANDROID_SERIAL=$device "$repo_root/scripts/test-android-launch-performance.sh"
fi

if (( needs_connection )) && [[ ${LOGSEQ_CHAT_ANDROID_E2E_CLEAR_BROWSER_STATE:-1} == 1 ]]; then
  browser_package=${LOGSEQ_CHAT_ANDROID_E2E_BROWSER_PACKAGE:-com.android.chrome}
  if adb -s "$device" shell pm path "$browser_package" >/dev/null 2>&1; then
    adb -s "$device" shell pm clear "$browser_package" >/dev/null
  fi
fi

if (( needs_connection )); then
  [[ $LOGSEQ_CHAT_E2E_BASE_URL != *['<>&"']* ]] \
    || die "LOGSEQ_CHAT_E2E_BASE_URL contains characters that are unsafe in Android preferences"
  preferences_file=$(mktemp "${TMPDIR:-/tmp}/logseq-chat-android-defaults.xml.XXXXXX")
  temporary_files+=("$preferences_file")
  remote_preferences="/data/local/tmp/logseq-chat-android-defaults-$$.xml"
  printf '%s\n' \
    "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>" \
    '<map>' \
    '    <string name="logseq.appearance">system</string>' \
    '    <string name="logseq.language">system</string>' \
    "    <string name=\"logseq.baseURL\">$LOGSEQ_CHAT_E2E_BASE_URL</string>" \
    '</map>' >"$preferences_file"
  adb -s "$device" push "$preferences_file" "$remote_preferences" >/dev/null
  adb -s "$device" shell run-as "$app_id" mkdir -p shared_prefs
  adb -s "$device" shell run-as "$app_id" cp "$remote_preferences" shared_prefs/defaults.xml
  adb -s "$device" shell rm -f "$remote_preferences"
fi

seed_android_outliner_fixture() {
  command -v opam >/dev/null 2>&1 || die "opam is required to seed the Android outliner fixture"
  local graph_database=""
  local checkpoint=""
  for _ in {1..120}; do
    graph_database=$(adb -s "$device" shell run-as "$app_id" \
      find files/graphs -name graph.sqlite -type f 2>/dev/null \
      | tr -d '\r' | head -1)
    checkpoint=${graph_database%/graph.sqlite}/sync.checkpoint
    if [[ -n $graph_database ]] && adb -s "$device" shell run-as "$app_id" \
      test -f "$checkpoint"; then
      break
    fi
    sleep 0.5
  done
  [[ -n $graph_database ]] || die "timed out waiting for the Android graph database"

  adb -s "$device" shell am force-stop "$app_id"
  local local_database
  local_database=$(mktemp "${TMPDIR:-/tmp}/logseq-chat-android-graph.XXXXXX")
  temporary_files+=("$local_database")
  adb -s "$device" exec-out run-as "$app_id" cat "$graph_database" >"$local_database"
  opam exec --switch=5.5.0 -- \
    dune exec core/logseq_chat_e2e_seed.exe -- "$local_database" --outliner

  local remote_database="/data/local/tmp/logseq-chat-android-graph-$$.sqlite"
  adb -s "$device" push "$local_database" "$remote_database" >/dev/null
  adb -s "$device" shell run-as "$app_id" \
    rm -f "${graph_database}-wal" "${graph_database}-shm"
  adb -s "$device" shell run-as "$app_id" cp "$remote_database" "$graph_database"
  adb -s "$device" shell rm -f "$remote_database"
}

for flow in "${flows[@]}"; do
  echo "==> $flow"
  if [[ $flow = /* ]]; then
    flow_path=$flow
  else
    flow_path="$repo_root/$flow"
  fi
  if [[ $flow == "$autocomplete_flow" ]]; then
    seed_android_outliner_fixture
  fi
  maestro_args=(--device "$device" test)
  if [[ $flow == "$connect_flow" ]]; then
    maestro_args+=(
      -e "USERNAME=$LOGSEQ_CHAT_E2E_USERNAME"
      -e "PASSWORD=$LOGSEQ_CHAT_E2E_PASSWORD"
    )
  fi
  MAESTRO_CLI_NO_ANALYTICS=1 maestro "${maestro_args[@]}" "$flow_path"
  if (( needs_primary_button )) \
    && [[ $flow == "$signed_out_flow" ]] \
    && [[ ${LOGSEQ_CHAT_ANDROID_E2E_SKIP_VISUAL_GATES:-0} != 1 ]]; then
    ANDROID_SERIAL=$device "$repo_root/scripts/test-android-primary-button.sh"
    ANDROID_SERIAL=$device "$repo_root/scripts/test-android-idle-rendering.sh"
  fi
done

echo "Android E2E '$selector' passed (${#flows[@]} flows)"
