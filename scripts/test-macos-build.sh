#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
build_script="$repo_root/scripts/build-macos-app.sh"
mobile_builder="$repo_root/scripts/build-mobile-ocaml.sh"
core_dune="$repo_root/core/dune"
bundle_test="$repo_root/scripts/test-macos-app-bundle.sh"
app_dir=${LOGSEQ_CHAT_MACOS_APP_DIR:-$repo_root/.build/macos/LogseqChat.app}
failures=0

check_succeeds() {
  local name=$1
  local expected=$2
  shift 2

  set +e
  local output
  output=$("$@" 2>&1)
  local status=$?
  set -e

  if [[ $status -ne 0 || $output != *"$expected"* ]]; then
    echo "not ok - $name" >&2
    echo "$output" >&2
    failures=$((failures + 1))
    return
  fi

  echo "ok - $name"
}

check_rejects() {
  local name=$1
  local expected=$2
  shift 2

  set +e
  local output
  output=$("$@" 2>&1)
  local status=$?
  set -e

  if [[ $status -eq 0 || $output != *"$expected"* ]]; then
    echo "not ok - $name" >&2
    echo "$output" >&2
    failures=$((failures + 1))
    return
  fi

  echo "ok - $name"
}

check_succeeds \
  "macOS build uses the OCaml 5.5 release toolchain" \
  "configuration=release ocaml-version=5.5.0" \
  env LOGSEQ_CHAT_MACOS_CONFIGURATION=release \
    LOGSEQ_CHAT_MACOS_PRINT_BUILD_SETTINGS=1 \
    "$build_script"

check_succeeds \
  "macOS build uses a deployment-targeted OCaml toolchain" \
  "toolchain=host-5.5.0-macos14.0" \
  env LOGSEQ_CHAT_MACOS_DEPLOYMENT_TARGET=14.0 \
    LOGSEQ_CHAT_MACOS_PRINT_BUILD_SETTINGS=1 \
    "$build_script"

check_rejects \
  "macOS build rejects unsupported configurations" \
  "unsupported macOS build configuration: profile" \
  env LOGSEQ_CHAT_MACOS_CONFIGURATION=profile \
    LOGSEQ_CHAT_MACOS_PRINT_BUILD_SETTINGS=1 \
    "$build_script"

grep -Fq 'scripts/build-mobile-ocaml.sh' "$build_script" || {
  echo "not ok - macOS build does not use the shared mobile OCaml builder" >&2
  failures=$((failures + 1))
}
[[ -x $mobile_builder ]] || {
  echo "not ok - shared mobile OCaml builder is not executable" >&2
  failures=$((failures + 1))
}

for module in \
  logseq_chat_edn \
  logseq_chat_entity_sync \
  logseq_chat_graph_read \
  logseq_chat_graph_store \
  logseq_chat_logseq_storage_codec \
  logseq_chat_snapshot \
  logseq_chat_sync_checkpoint \
  logseq_chat_sync_protocol \
  logseq_chat_sync_session \
  logseq_chat_sync_state; do
  if ! grep -Eq "^[[:space:]]+$module[)]?$" "$core_dune"; then
    echo "not ok - shared mobile core omits OCaml module: $module" >&2
    failures=$((failures + 1))
  fi
done

if ! grep -q 'logseq_chat_graph_store_stubs' "$core_dune"; then
  echo "not ok - shared mobile core omits native graph storage stubs" >&2
  failures=$((failures + 1))
fi

check_succeeds \
  "macOS app bundle links the native OCaml core" \
  "ok - native OCaml core is linked" \
  env LOGSEQ_CHAT_MACOS_APP_DIR="$app_dir" \
    "$bundle_test"

if [[ $failures -ne 0 ]]; then
  exit 1
fi
