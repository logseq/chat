#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
app_id=com.logseq.chat
signed_out_flow=tests/e2e/android-signed-out.yaml
local_setup_flow=tests/e2e/android-local-graph-setup.yaml
connect_flow=tests/e2e/android-staging-connect.yaml
capture_flow=tests/e2e/android-capture-search.yaml
composer_flow=tests/e2e/android-composer-lifecycle.yaml
autocomplete_flow=tests/e2e/android-outliner-autocomplete-completion.yaml
outliner_flow=tests/e2e/android-outliner-interactions.yaml
hierarchy_flow=tests/e2e/android-outliner-hierarchy-navigation.yaml
audio_flow=tests/e2e/android-audio-recording.yaml
navigation_flow=tests/e2e/android-material-navigation.yaml
graphs_flow=tests/e2e/android-graphs.yaml
settings_flow=tests/e2e/android-settings.yaml
flashcards_flow=tests/e2e/android-flashcards-regression.yaml
search_flow=tests/e2e/android-search-navigation.yaml
rich_content_flow=tests/e2e/android-rich-block-rendering.yaml
youtube_flow=tests/e2e/android-youtube-playback.yaml
node_tag_flow=tests/e2e/android-node-tag-navigation.yaml
page_actions_flow=tests/e2e/android-page-actions.yaml
shortcuts_flow=tests/e2e/android-shortcut-deep-links.yaml
sharing_flow=tests/e2e/android-share-capture.yaml
editor_regressions_flow=tests/e2e/android-rapid-enter-delete-regression.yaml
sharing_image_flow=tests/e2e/android-share-image.yaml

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
      "$composer_flow"
      "$autocomplete_flow"
      "$outliner_flow"
      "$hierarchy_flow"
      "$audio_flow"
      "$navigation_flow"
      "$graphs_flow"
      "$settings_flow"
      "$flashcards_flow"
      "$search_flow"
      "$rich_content_flow"
      "$youtube_flow"
      "$node_tag_flow"
      "$page_actions_flow"
      "$shortcuts_flow"
      "$sharing_flow"
      "$editor_regressions_flow"
      "$sharing_image_flow"
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
  smoke)
    # Fresh-install smoke: bypass hosted sign-in, create a local graph, then
    # run the capture assertions. Works without backend credentials.
    flows=("$signed_out_flow" "$local_setup_flow" "$capture_flow")
    needs_connection=0
    needs_clear_state=1
    needs_primary_button=0
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
  composer)
    flows=("$composer_flow")
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
  outliner)
    flows=("$outliner_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  hierarchy)
    flows=("$hierarchy_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  audio)
    flows=("$audio_flow")
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
  settings)
    flows=("$settings_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  flashcards)
    flows=("$flashcards_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  search)
    flows=("$search_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  rich-content)
    flows=("$rich_content_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  youtube)
    flows=("$youtube_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  node-tag)
    flows=("$node_tag_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  page-actions)
    flows=("$page_actions_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  shortcuts)
    flows=("$shortcuts_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  sharing)
    flows=("$sharing_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  editor-regressions)
    flows=("$editor_regressions_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  sharing-image)
    flows=("$sharing_image_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  --list)
    echo "Modules: all signed-out smoke connect capture composer autocomplete outliner hierarchy audio navigation graphs settings flashcards search rich-content youtube node-tag page-actions shortcuts sharing editor-regressions sharing-image"
    printf '%s\n' \
      "$signed_out_flow" \
      "$connect_flow" \
      "$capture_flow" \
      "$composer_flow" \
      "$autocomplete_flow" \
      "$outliner_flow" \
      "$hierarchy_flow" \
      "$audio_flow" \
      "$navigation_flow" \
      "$graphs_flow" \
      "$settings_flow" \
      "$flashcards_flow" \
      "$search_flow" \
      "$rich_content_flow" \
      "$youtube_flow" \
      "$node_tag_flow" \
      "$page_actions_flow" \
      "$shortcuts_flow" \
      "$sharing_flow" \
      "$editor_regressions_flow" \
      "$sharing_image_flow"
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
# Modules that still sign in through the in-app Cognito form (e.g. smoke's
# local server setup) use the shared dev-account defaults.
LOGSEQ_CHAT_E2E_USERNAME=${LOGSEQ_CHAT_E2E_USERNAME:-e2etest}
LOGSEQ_CHAT_E2E_PASSWORD=${LOGSEQ_CHAT_E2E_PASSWORD:-Logseq-e2e}

command -v adb >/dev/null 2>&1 || die "adb is not installed"
command -v maestro >/dev/null 2>&1 || die "Maestro CLI is not installed"
command -v flutter >/dev/null 2>&1 || die "Flutter is not installed"

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

if [[ -n ${LOGSEQ_CHAT_E2E_BASE_URL:-} ]] \
  && [[ $LOGSEQ_CHAT_E2E_BASE_URL =~ ^(http|https)://(127\.0\.0\.1|localhost)(:([0-9]+))?([/?#]|$) ]]; then
  local_backend_port=${BASH_REMATCH[4]:-}
  if [[ -z $local_backend_port ]]; then
    if [[ ${BASH_REMATCH[1]} == https ]]; then
      local_backend_port=443
    else
      local_backend_port=80
    fi
  fi
  adb -s "$device" reverse "tcp:$local_backend_port" "tcp:$local_backend_port"
fi

if [[ ${LOGSEQ_CHAT_ANDROID_E2E_SKIP_BUILD:-0} != 1 ]]; then
  (
    cd "$repo_root/flutter"
    ANDROID_SERIAL=$device flutter build apk --debug
  )
fi

if [[ ${LOGSEQ_CHAT_ANDROID_E2E_SKIP_INSTALL:-0} != 1 ]]; then
  apk="$repo_root/flutter/build/app/outputs/flutter-apk/app-debug.apk"
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

if [[ -n ${LOGSEQ_CHAT_E2E_BASE_URL:-} ]]; then
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

seed_android_fixture() {
  local seed_mode=${1:-}
  command -v opam >/dev/null 2>&1 || die "opam is required to seed the Android fixture"
  local selected_graph_id=""
  local graph_database=""
  local checkpoint=""
  local graph_ready=0
  for _ in {1..120}; do
    selected_graph_id=$(adb -s "$device" shell run-as "$app_id" \
      cat shared_prefs/logseq_chat.xml 2>/dev/null \
      | sed -n 's|.*<string name="logseq.selectedGraphId">\([^<]*\)</string>.*|\1|p' \
      | tr -d '\r' | head -1)
    if [[ $selected_graph_id =~ ^[A-Za-z0-9._-]+$ ]]; then
      graph_database="files/graphs/$selected_graph_id/graph.sqlite"
      checkpoint="files/graphs/$selected_graph_id/sync.checkpoint"
    fi
    if [[ -n $graph_database ]] \
      && adb -s "$device" shell run-as "$app_id" test -f "$graph_database" \
      && adb -s "$device" shell run-as "$app_id" test -f "$checkpoint"; then
      graph_ready=1
      break
    fi
    sleep 0.5
  done
  (( graph_ready )) \
    || die "timed out waiting for the selected Android graph database"

  adb -s "$device" shell am force-stop "$app_id"
  local local_database
  local_database=$(mktemp "${TMPDIR:-/tmp}/logseq-chat-android-graph.XXXXXX")
  temporary_files+=("$local_database")
  adb -s "$device" exec-out run-as "$app_id" cat "$graph_database" >"$local_database"
  local dune_seed=()
  if command -v dune >/dev/null 2>&1; then
    dune_seed=(dune exec)
  else
    dune_seed=(opam exec --switch=5.5.0 -- dune exec)
  fi
  if [[ -n $seed_mode ]]; then
    "${dune_seed[@]}" shared/native/logseq_chat_e2e_seed.exe -- "$local_database" "$seed_mode"
  else
    "${dune_seed[@]}" shared/native/logseq_chat_e2e_seed.exe -- "$local_database"
  fi

  local remote_database="/data/local/tmp/logseq-chat-android-graph-$$.sqlite"
  adb -s "$device" push "$local_database" "$remote_database" >/dev/null
  adb -s "$device" shell run-as "$app_id" \
    rm -f "${graph_database}-wal" "${graph_database}-shm"
  adb -s "$device" shell run-as "$app_id" cp "$remote_database" "$graph_database"
  adb -s "$device" shell rm -f "$remote_database"
}

if [[ -n ${LOGSEQ_CHAT_E2E_BASE_URL:-} ]] \
  && [[ $LOGSEQ_CHAT_E2E_BASE_URL =~ ^(http|https)://(127\.0\.0\.1|localhost)(:([0-9]+))?([/?#]|$) ]]; then
  # CI builds db-sync in a background process; flows must not start before
  # it binds the port (a bound port returns any HTTP response, incl. 401/404).
  for attempt in $(seq 1 180); do
    if curl -s -o /dev/null "${LOGSEQ_CHAT_E2E_BASE_URL}/"; then
      break
    fi
    if (( attempt == 180 )); then
      die "db-sync server did not come up at $LOGSEQ_CHAT_E2E_BASE_URL"
    fi
    sleep 2
  done
fi

for flow in "${flows[@]}"; do
  echo "==> $flow"
  if [[ $flow = /* ]]; then
    flow_path=$flow
  else
    flow_path="$repo_root/$flow"
  fi
  if [[ ${LOGSEQ_CHAT_ANDROID_E2E_SKIP_SEED:-0} != 1 ]]; then
    if [[ $flow == "$autocomplete_flow" ]]; then
      seed_android_fixture --outliner
    elif [[ $flow == "$outliner_flow" ]]; then
      seed_android_fixture --outliner
    elif [[ $flow == "$hierarchy_flow" ]]; then
      seed_android_fixture --outliner
    elif [[ $flow == "$audio_flow" ]]; then
      seed_android_fixture --outliner
    elif [[ $flow == "$navigation_flow" ]]; then
      seed_android_fixture --fixture
    elif [[ $flow == "$flashcards_flow" ]]; then
      seed_android_fixture --fixture
    elif [[ $flow == "$search_flow" ]]; then
      seed_android_fixture --fixture
    elif [[ $flow == "$rich_content_flow" ]]; then
      seed_android_fixture --fixture
    elif [[ $flow == "$node_tag_flow" ]]; then
      seed_android_fixture --fixture
    elif [[ $flow == "$page_actions_flow" ]]; then
      seed_android_fixture --fixture
    elif [[ $flow == "$editor_regressions_flow" ]]; then
      seed_android_fixture --outliner
    fi
  fi
  if [[ $flow == "$sharing_flow" ]]; then
    adb -s "$device" shell am start -W \
      -a android.intent.action.SEND \
      -t text/plain \
      --es android.intent.extra.TEXT https://example.com/android-share \
      --es android.intent.extra.TITLE 'Android\ share' \
      "$app_id/.MainActivity" >/dev/null
  elif [[ $flow == "$sharing_image_flow" ]]; then
    share_image="$repo_root/apple/App/Assets.xcassets/AppIcon.appiconset/AppIcon-20~ipad.png"
    [[ -f $share_image ]] || die "Android image-share fixture is missing"
    remote_share_image="/data/local/tmp/logseq-chat-e2e-share.png"
    app_share_image="files/logseq-chat-e2e-share.png"
    adb -s "$device" push "$share_image" "$remote_share_image" >/dev/null
    adb -s "$device" shell run-as "$app_id" cp "$remote_share_image" "$app_share_image"
    adb -s "$device" shell rm -f "$remote_share_image"
    adb -s "$device" shell am start -W \
      -a android.intent.action.SEND \
      -t image/png \
      --eu android.intent.extra.STREAM \
      "file:///data/user/0/$app_id/$app_share_image" \
      "$app_id/.MainActivity" >/dev/null
  fi
  maestro_args=(--device "$device" test)
  if [[ $flow == "$connect_flow" || $flow == "$local_setup_flow" ]]; then
    maestro_args+=(
      -e "USERNAME=$LOGSEQ_CHAT_E2E_USERNAME"
      -e "PASSWORD=$LOGSEQ_CHAT_E2E_PASSWORD"
    )
  fi
  MAESTRO_CLI_NO_ANALYTICS=1 maestro "${maestro_args[@]}" "$flow_path"
  if [[ $flow == "$sharing_image_flow" ]]; then
    adb -s "$device" shell run-as "$app_id" rm -f "$app_share_image"
  fi
  if (( needs_primary_button )) \
    && [[ $flow == "$signed_out_flow" ]] \
    && [[ ${LOGSEQ_CHAT_ANDROID_E2E_SKIP_VISUAL_GATES:-0} != 1 ]]; then
    ANDROID_SERIAL=$device "$repo_root/scripts/test-android-primary-button.sh"
    ANDROID_SERIAL=$device "$repo_root/scripts/test-android-idle-rendering.sh"
  fi
done

echo "Android E2E '$selector' passed (${#flows[@]} flows)"
