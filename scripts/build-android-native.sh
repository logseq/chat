#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ocaml_version=${LOGSEQ_CHAT_ANDROID_OCAML_VERSION:-5.5.0}
android_abi=${LOGSEQ_CHAT_ANDROID_ABI:-arm64-v8a}
api_level=${LOGSEQ_CHAT_ANDROID_API_LEVEL:-21}
android_home=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}

die() {
  echo "error: $*" >&2
  exit 1
}

case "$android_abi" in
  arm64-v8a)
    target_arch=aarch64
    ;;
  x86_64)
    target_arch=x86_64
    ;;
  *)
    die "unsupported Android ABI: $android_abi"
    ;;
esac

target="${target_arch}-linux-android${api_level}"
target_prefix="$repo_root/_build/android-toolchain/$target-$ocaml_version"
build_dir="$repo_root/_build/android-core/$android_abi"
jni_dir="$repo_root/Android/app/src/main/jniLibs/$android_abi"
library="$build_dir/liblogseq_chat_core.so"

"$repo_root/scripts/bootstrap-android-ocaml.sh" >/dev/null

if [[ -d ${ANDROID_NDK_HOME:-} ]]; then
  ndk_root=$ANDROID_NDK_HOME
else
  ndk_root=
  for candidate in "$android_home"/ndk/*; do
    [[ -d $candidate ]] && ndk_root=$candidate
  done
fi
[[ -n ${ndk_root:-} && -d $ndk_root ]] || die "Android NDK is not installed under $android_home/ndk"

case "$(uname -s)" in
  Darwin)
    ndk_host=darwin-x86_64
    ;;
  Linux)
    ndk_host=linux-x86_64
    ;;
  *)
    die "unsupported build host: $(uname -s)"
    ;;
esac

ndk_bin="$ndk_root/toolchains/llvm/prebuilt/$ndk_host/bin"
ocamlopt="$target_prefix/bin/ocamlopt.opt"
ocaml_lib="$target_prefix/lib/ocaml"

mkdir -p "$build_dir" "$jni_dir"
"$repo_root/scripts/build-mobile-ocaml-deps.sh" \
  "$target_prefix" \
  "$build_dir"
dependency_dir="$build_dir/mobile-ocaml-deps"
dependency_objects=()
while IFS= read -r object; do
  dependency_objects+=("$object")
done <"$dependency_dir/link-objects.txt"
sqlite_stub_source=$(<"$dependency_dir/sqlite-stub-source.txt")
sqlite_source_dir=$("$repo_root/scripts/build-android-sqlite.sh")

cd "$build_dir"

"$ocamlopt" -I "$dependency_dir" -c -o logseq_chat_model.cmx \
  "$repo_root/core/logseq_chat_model.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_edn.cmx \
  "$repo_root/core/logseq_chat_edn.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_sync_protocol.cmx \
  "$repo_root/core/logseq_chat_sync_protocol.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_sync_state.cmx \
  "$repo_root/core/logseq_chat_sync_state.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_sync_checkpoint.cmx \
  "$repo_root/core/logseq_chat_sync_checkpoint.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_snapshot.cmx \
  "$repo_root/core/logseq_chat_snapshot.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_entity_sync.cmx \
  "$repo_root/core/logseq_chat_entity_sync.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_ref_text.cmx \
  "$repo_root/core/logseq_chat_ref_text.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_graph_read.cmx \
  "$repo_root/core/logseq_chat_graph_read.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_sse.cmx \
  "$repo_root/core/logseq_chat_sse.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_api.cmx \
  "$repo_root/core/logseq_chat_api.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_http.cmx \
  "$repo_root/core/logseq_chat_http.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_rpc.cmx \
  "$repo_root/core/logseq_chat_rpc.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_logseq_storage_codec.cmx \
  "$repo_root/core/logseq_chat_logseq_storage_codec.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_graph_store.cmx \
  "$repo_root/core/logseq_chat_graph_store.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_sync_session.cmx \
  "$repo_root/core/logseq_chat_sync_session.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_sqlite.cmx \
  "$repo_root/core/logseq_chat_sqlite.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_mobile_entry.cmx \
  "$repo_root/core/logseq_chat_mobile_entry.ml"

"$ocamlopt" \
  -I . \
  -I "$dependency_dir" \
  -I +threads \
  -thread \
  -runtime-variant _pic \
  -output-complete-obj \
  -linkall \
  -o logseq_chat_runtime.o \
  str.cmxa \
  unix.cmxa \
  threads.cmxa \
  "${dependency_objects[@]}" \
  logseq_chat_model.cmx \
  logseq_chat_edn.cmx \
  logseq_chat_sync_protocol.cmx \
  logseq_chat_sync_state.cmx \
  logseq_chat_sync_checkpoint.cmx \
  logseq_chat_snapshot.cmx \
  logseq_chat_entity_sync.cmx \
  logseq_chat_ref_text.cmx \
  logseq_chat_graph_read.cmx \
  logseq_chat_sse.cmx \
  logseq_chat_api.cmx \
  logseq_chat_http.cmx \
  logseq_chat_rpc.cmx \
  logseq_chat_logseq_storage_codec.cmx \
  logseq_chat_graph_store.cmx \
  logseq_chat_sync_session.cmx \
  logseq_chat_sqlite.cmx \
  logseq_chat_mobile_entry.cmx

"$ndk_bin/clang" \
  --target="$target" \
  -fPIC \
  -I "$ocaml_lib" \
  -c "$repo_root/core/logseq_chat_core_ffi.c" \
  -o logseq_chat_core_ffi.o

"$ndk_bin/clang" \
  --target="$target" \
  -fPIC \
  -I "$ocaml_lib" \
  -I "$ndk_root/toolchains/llvm/prebuilt/$ndk_host/sysroot/usr/include" \
  -c "$repo_root/core/logseq_chat_https_android.c" \
  -o logseq_chat_https_android.o

"$ndk_bin/clang" \
  --target="$target" \
  -fPIC \
  -I "$ocaml_lib" \
  -I "$sqlite_source_dir" \
  -c "$repo_root/core/logseq_chat_graph_store_stubs.c" \
  -o logseq_chat_graph_store_stubs.o

"$ndk_bin/clang" \
  --target="$target" \
  -fPIC \
  -I "$ocaml_lib" \
  -I "$sqlite_source_dir" \
  -c "$sqlite_stub_source" \
  -o datascript_sqlite_stubs.o

"$ndk_bin/clang" \
  --target="$target" \
  -fPIC \
  -O2 \
  -D_FILE_OFFSET_BITS=64 \
  -DSQLITE_OMIT_LOAD_EXTENSION \
  -DSQLITE_THREADSAFE=1 \
  -c "$sqlite_source_dir/sqlite3.c" \
  -o sqlite3.o

"$ndk_bin/clang" \
  --target="$target" \
  -shared \
  -Wl,--no-undefined \
  -Wl,-soname,liblogseq_chat_core.so \
  -o "$library" \
  logseq_chat_runtime.o \
  logseq_chat_core_ffi.o \
  logseq_chat_https_android.o \
  logseq_chat_graph_store_stubs.o \
  datascript_sqlite_stubs.o \
  sqlite3.o \
  -lm \
  -ldl \
  -llog \
  -pthread

"$ndk_bin/llvm-strip" --strip-unneeded "$library"
cp "$library" "$jni_dir/liblogseq_chat_core.so"

"$ndk_bin/llvm-readelf" -h "$library" \
  | grep "Machine:.*AArch64\\|Machine:.*Advanced Micro Devices X86-64" \
  >/dev/null
"$ndk_bin/llvm-readelf" -s "$library" | grep "logseq_chat_call" >/dev/null

echo "$jni_dir/liblogseq_chat_core.so"
