#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
runner="$repo_root/scripts/test-android-e2e.sh"

die() {
  echo "error: $*" >&2
  exit 1
}

list_output=$($runner --list) || die "Android E2E runner could not list modules"
grep -Fq "Modules: all signed-out connect capture autocomplete navigation graphs" <<<"$list_output" \
  || die "Android E2E runner did not list every module"
grep -Fq ".maestro/android-staging-connect.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the connection flow"
grep -Fq ".maestro/android-signed-out.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the signed-out flow"
grep -Fq ".maestro/android-capture-search.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the capture flow"
grep -Fq ".maestro/android-outliner-autocomplete-completion.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the autocomplete flow"
grep -Fq ".maestro/android-material-navigation.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the Material navigation flow"
grep -Fq ".maestro/android-graphs.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the graph presentation flow"

invalid_output=$(mktemp "${TMPDIR:-/tmp}/logseq-chat-android-e2e-invalid.XXXXXX")
missing_output=$(mktemp "${TMPDIR:-/tmp}/logseq-chat-android-e2e-missing.XXXXXX")
mock_bin=$(mktemp -d "${TMPDIR:-/tmp}/logseq-chat-android-e2e-bin.XXXXXX")
custom_flow=$(mktemp "${TMPDIR:-/tmp}/logseq-chat-android-e2e-flow.XXXXXX.yaml")
maestro_args=$(mktemp "${TMPDIR:-/tmp}/logseq-chat-android-e2e-maestro.XXXXXX")
trap 'rm -rf "$mock_bin"; rm -f "$invalid_output" "$missing_output" "$custom_flow" "$maestro_args"' EXIT

if LOGSEQ_CHAT_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_CHAT_ANDROID_E2E_SKIP_INSTALL=1 \
  "$runner" unsupported >"$invalid_output" 2>&1; then
  die "Android E2E runner accepted an unknown module"
fi
grep -Fq "unknown Android E2E module or flow: unsupported" "$invalid_output" \
  || die "Android E2E runner did not explain the unknown module"

if env -u LOGSEQ_CHAT_E2E_USERNAME \
  -u LOGSEQ_CHAT_E2E_PASSWORD \
  -u LOGSEQ_CHAT_E2E_BASE_URL \
  LOGSEQ_CHAT_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_CHAT_ANDROID_E2E_SKIP_INSTALL=1 \
  "$runner" connect >"$missing_output" 2>&1; then
  die "Android E2E runner accepted missing connection parameters"
fi
grep -Fq "LOGSEQ_CHAT_E2E_USERNAME is required" "$missing_output" \
  || die "Android E2E runner did not explain the missing connection parameter"

printf '#!/usr/bin/env bash\nexit 0\n' >"$mock_bin/adb"
printf '#!/usr/bin/env bash\nprintf \"%%s\\n\" \"$@\" >\"$LOGSEQ_CHAT_MAESTRO_ARGS\"\n' >"$mock_bin/maestro"
printf '#!/usr/bin/env bash\nexit 0\n' >"$mock_bin/gradle"
chmod +x "$mock_bin/adb" "$mock_bin/maestro" "$mock_bin/gradle"
printf 'appId: com.logseq.chat\n---\n- launchApp\n' >"$custom_flow"

PATH="$mock_bin:$PATH" \
  ANDROID_SERIAL=test-device \
  LOGSEQ_CHAT_MAESTRO_ARGS="$maestro_args" \
  LOGSEQ_CHAT_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_CHAT_ANDROID_E2E_SKIP_INSTALL=1 \
  "$runner" "$custom_flow" >/dev/null
[[ $(tail -n 1 "$maestro_args") == "$custom_flow" ]] \
  || die "Android E2E runner changed an absolute custom flow path"

PATH="$mock_bin:$PATH" \
  ANDROID_SERIAL=test-device \
  LOGSEQ_CHAT_MAESTRO_ARGS="$maestro_args" \
  LOGSEQ_CHAT_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_CHAT_ANDROID_E2E_SKIP_INSTALL=1 \
  LOGSEQ_CHAT_E2E_USERNAME=test-user \
  LOGSEQ_CHAT_E2E_PASSWORD=test-password \
  LOGSEQ_CHAT_E2E_BASE_URL=https://api.example \
  "$runner" connect >/dev/null
expected_connect_args=$(printf '%s\n' \
  --device test-device test \
  -e USERNAME=test-user \
  -e PASSWORD=test-password \
  "$repo_root/.maestro/android-staging-connect.yaml")
[[ $(<"$maestro_args") == "$expected_connect_args" ]] \
  || die "Android E2E runner passed Maestro environment options outside the test command"

PATH="$mock_bin:$PATH" \
  ANDROID_SERIAL=test-device \
  LOGSEQ_CHAT_MAESTRO_ARGS="$maestro_args" \
  LOGSEQ_CHAT_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_CHAT_ANDROID_E2E_SKIP_INSTALL=1 \
  "$runner" navigation >/dev/null
expected_navigation_args=$(printf '%s\n' \
  --device test-device test \
  "$repo_root/.maestro/android-material-navigation.yaml")
[[ $(<"$maestro_args") == "$expected_navigation_args" ]] \
  || die "Android E2E runner did not preserve the Material navigation flow"

PATH="$mock_bin:$PATH" \
  ANDROID_SERIAL=test-device \
  LOGSEQ_CHAT_MAESTRO_ARGS="$maestro_args" \
  LOGSEQ_CHAT_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_CHAT_ANDROID_E2E_SKIP_INSTALL=1 \
  "$runner" graphs >/dev/null
expected_graphs_args=$(printf '%s\n' \
  --device test-device test \
  "$repo_root/.maestro/android-graphs.yaml")
[[ $(<"$maestro_args") == "$expected_graphs_args" ]] \
  || die "Android E2E runner did not preserve the graph presentation flow"

echo "Android E2E runner tests passed"
