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
  grep -F -- "$pattern" "$repo_root/$path" >/dev/null || fail "$path does not contain: $pattern"
}

reject_text() {
  local path=$1
  local pattern=$2
  if [[ -f $repo_root/$path ]] && grep -F -- "$pattern" "$repo_root/$path" >/dev/null; then
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
require_text "scripts/build-android-native.sh" "logseq_chat_crypto_android.c"
require_file "core/logseq_chat_crypto_android.c"
require_file "Sources/LogseqChat/Skip/AndroidE2EECrypto.kt"
require_text "core/logseq_chat_https_android.c" "logseq_chat_crypto_jni_init"
require_text "Sources/LogseqChat/Skip/AndroidE2EECrypto.kt" "RSA/ECB/OAEPWithSHA-256AndMGF1Padding"
reject_text "core/logseq_chat_crypto_android.c" "Android crypto is not implemented"
for module in \
  logseq_chat_edn \
  logseq_chat_sync_protocol \
  logseq_chat_sync_state \
  logseq_chat_sync_checkpoint \
  logseq_chat_snapshot \
  logseq_chat_entity_sync \
  logseq_chat_datascript_value \
  logseq_chat_graph_read \
  logseq_chat_e2ee \
  logseq_chat_outliner_state \
  logseq_chat_graph_runtime \
  logseq_chat_sse \
  logseq_chat_logseq_storage_codec \
  logseq_chat_graph_store \
  logseq_chat_sync_session; do
  require_text "scripts/build-android-native.sh" "$module.cmx"
done
require_text "scripts/build-android-native.sh" "logseq_chat_graph_store_stubs.c"
require_text "scripts/build-android-native.sh" "logseq_chat_graph_store_stubs.o"
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
require_text "Android/app/build.gradle.kts" "LOGSEQ_CHAT_ANDROID_ABIS"
require_text "Android/app/build.gradle.kts" "x86_64"
require_text "scripts/build-android-native.sh" "x86_64"
require_text "Android/gradle/wrapper/gradle-wrapper.properties" "gradle-9.4.1-bin.zip"

if [[ $failures -ne 0 ]]; then
  exit 1
fi

echo "ok - Android native OCaml build script is wired"
