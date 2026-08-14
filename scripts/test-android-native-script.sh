#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
failures=0

fail() {
  echo "not ok - $*" >&2
  failures=$((failures + 1))
}

require_file() {
  local path=$1
  [[ -f $repo_root/$path ]] || fail "missing $path"
}

require_text() {
  local path=$1
  local pattern=$2
  if [[ ! -f $repo_root/$path ]]; then
    fail "missing $path"
    return
  fi
  grep -F "$pattern" "$repo_root/$path" >/dev/null || fail "$path does not contain: $pattern"
}

reject_text() {
  local path=$1
  local pattern=$2
  if [[ -f $repo_root/$path ]] && grep -F "$pattern" "$repo_root/$path" >/dev/null; then
    fail "$path unexpectedly contains: $pattern"
  fi
}

require_file "scripts/bootstrap-android-ocaml.sh"
require_file "scripts/build-android-sqlite.sh"
require_file "scripts/build-android-native.sh"

require_text "scripts/build-android-native.sh" "liblogseq_chat_core.so"
require_text "scripts/build-android-native.sh" 'Android/app/src/main/jniLibs/$android_abi'
require_text "scripts/build-android-native.sh" "logseq_chat_call"
require_text "scripts/build-android-native.sh" "logseq_chat_https_android.c"
require_text "core/logseq_chat_https_android.c" "JNI_OnLoad"
require_text "core/logseq_chat_https_android.c" "AndroidHttpTransport"
require_text "Android/app/src/main/kotlin/AndroidHttpTransport.kt" "connectTimeout = 30_000"
require_text "Android/app/src/main/kotlin/AndroidHttpTransport.kt" "outputStream.use"
require_text "Android/app/src/main/kotlin/Main.kt" 'System.loadLibrary("logseq_chat_core")'
require_text "Sources/LogseqChat/Skip/AndroidAssetImporter.kt" "OpenMultipleDocuments"
require_text "Sources/LogseqChat/Skip/AndroidAssetImporter.kt" "contentResolver.openInputStream"
reject_text "scripts/build-android-native.sh" "logseq_chat_https_stub.c"
require_text "Android/app/build.gradle.kts" "buildAndroidNativeCore"
require_text "Android/app/build.gradle.kts" "scripts/build-android-native.sh"

if [[ $failures -ne 0 ]]; then
  exit 1
fi

echo "ok - Android native OCaml build script is wired"
