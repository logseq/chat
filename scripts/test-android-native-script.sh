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
require_file "scripts/build-mobile-ocaml.sh"
require_file "scripts/build-android-native.sh"

require_text "scripts/build-android-native.sh" "liblogseq_chat_core.so"
require_text "scripts/build-android-native.sh" 'Flutter/android/app/src/main/jniLibs/$android_abi'
require_text "scripts/build-android-native.sh" "logseq_chat_call"
require_text "core/logseq_chat_core_ffi.h" "logseq_chat_lui_root_node"
require_text "core/logseq_chat_core_ffi.c" "logseq_chat_lui_root_node"
require_text "scripts/build-android-native.sh" "logseq_chat_https_android.c"
require_text "scripts/build-android-native.sh" "logseq_chat_crypto_android.c"
require_text "scripts/build-android-native.sh" 'scripts/build-mobile-ocaml.sh'
require_text "scripts/build-android-native.sh" 'DATASCRIPT_SQLITE_LIB_DIR="$build_dir"'
require_text "scripts/build-android-native.sh" "-DSQLITE_ENABLE_FTS5"
require_text "scripts/build-android-native.sh" 'llvm-nm" sqlite3.o'
require_text "scripts/build-android-native.sh" 'sqlite3Fts5Init'
require_text "core/dune" "link_deps"
require_text "core/dune" '%{env:LOGSEQ_CHAT_SQLITE_LINK_FILE=./libsqlite3.a}'
require_text "scripts/build-android-native.sh" 'LOGSEQ_CHAT_SQLITE_LINK_FILE="$build_dir/libsqlite3.a"'
require_file "core/logseq_chat_crypto_android.c"
require_file "Flutter/android/app/src/main/kotlin/logseq/chat/AndroidE2EECrypto.kt"
require_text "core/logseq_chat_https_android.c" "logseq_chat_crypto_jni_init"
require_text "Flutter/android/app/src/main/kotlin/logseq/chat/AndroidE2EECrypto.kt" "RSA/ECB/OAEPWithSHA-256AndMGF1Padding"
reject_text "core/logseq_chat_crypto_android.c" "Android crypto is not implemented"
for forbidden in ".cmx" "ocamlopt" "output-complete-obj" "link-objects.txt" "build-mobile-ocaml-deps.sh"; do
  reject_text "scripts/build-android-native.sh" "$forbidden"
done
require_text "core/logseq_chat_https_android.c" "JNI_OnLoad"
require_text "core/logseq_chat_https_android.c" "AndroidHttpTransport"
require_text "Flutter/android/app/src/main/kotlin/logseq/chat/AndroidHttpTransport.kt" "connectTimeout = 30_000"
require_text "Flutter/android/app/src/main/kotlin/logseq/chat/AndroidHttpTransport.kt" "outputStream.use"
require_text "Flutter/android/app/src/main/kotlin/logseq/chat/AndroidHttpTransport.kt" "resolveAndroidFile"
require_text "Flutter/android/app/src/main/kotlin/com/logseq/logseq_chat_flutter/MainActivity.kt" "AndroidHttpTransport.initialize(applicationContext)"
require_text "Flutter/android/app/src/main/kotlin/com/logseq/logseq_chat_flutter/MainActivity.kt" 'System.loadLibrary("logseq_chat_core")'
require_text "Flutter/android/app/src/main/kotlin/com/logseq/chat/AndroidAssetImporter.kt" "Intent.ACTION_OPEN_DOCUMENT"
require_text "Flutter/android/app/src/main/kotlin/com/logseq/chat/AndroidAssetImporter.kt" "Intent.EXTRA_ALLOW_MULTIPLE"
require_text "Flutter/android/app/src/main/kotlin/com/logseq/chat/AndroidAssetImporter.kt" "contentResolver.openInputStream"
reject_text "scripts/build-android-native.sh" "logseq_chat_https_stub.c"
require_text "Flutter/android/app/build.gradle.kts" "buildAndroidNativeCore"
require_text "Flutter/android/app/build.gradle.kts" "scripts/build-android-native.sh"
require_text "Flutter/android/app/build.gradle.kts" 'dependsOn("buildAndroidNativeCore")'
require_text "Flutter/android/app/build.gradle.kts" "inputs.files"
require_text "Flutter/android/app/build.gradle.kts" "outputs.file"
require_text "scripts/test-android-e2e.sh" "logseq.selectedGraphId"
reject_text "scripts/test-android-e2e.sh" "find files/graphs -name graph.sqlite -type f"

if [[ $failures -ne 0 ]]; then
  exit 1
fi

echo "ok - Android native OCaml build script is wired"
