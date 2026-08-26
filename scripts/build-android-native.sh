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
    dune_context=android_arm64
    ;;
  x86_64)
    target_arch=x86_64
    dune_context=android_x86_64
    ;;
  *) die "unsupported Android ABI: $android_abi" ;;
esac

target="${target_arch}-linux-android${api_level}"
target_prefix="$repo_root/_build/android-toolchain/$target-$ocaml_version"
build_dir="$repo_root/_build/android-core/$android_abi"
jni_dir="$repo_root/Android/app/src/main/jniLibs/$android_abi"
library="$build_dir/liblogseq_chat_core.so"

"$repo_root/scripts/bootstrap-android-ocaml.sh" >/dev/null

case "$(uname -s)" in
  Darwin) ndk_host=darwin-x86_64 ;;
  Linux) ndk_host=linux-x86_64 ;;
  *) die "unsupported build host: $(uname -s)" ;;
esac

if [[ -d ${ANDROID_NDK_HOME:-} ]]; then
  ndk_root=$ANDROID_NDK_HOME
else
  ndk_root=
  for candidate in "$android_home"/ndk/*; do
    [[ -x $candidate/toolchains/llvm/prebuilt/$ndk_host/bin/clang ]] && ndk_root=$candidate
  done
fi
[[ -n ${ndk_root:-} && -d $ndk_root ]] || die "Android NDK is not installed under $android_home/ndk"

ndk_bin="$ndk_root/toolchains/llvm/prebuilt/$ndk_host/bin"
ocaml_lib="$target_prefix/lib/ocaml"
sqlite_source_dir=$("$repo_root/scripts/build-android-sqlite.sh")

mkdir -p "$build_dir" "$jni_dir"
cd "$build_dir"

"$ndk_bin/clang" \
  --target="$target" \
  -fPIC \
  -O2 \
  -D_FILE_OFFSET_BITS=64 \
  -DSQLITE_OMIT_LOAD_EXTENSION \
  -DSQLITE_THREADSAFE=1 \
  -c "$sqlite_source_dir/sqlite3.c" \
  -o sqlite3.o
"$ndk_bin/llvm-ar" rcs libsqlite3.a sqlite3.o

runtime_object=$(C_INCLUDE_PATH="$sqlite_source_dir${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}" \
  DATASCRIPT_SQLITE_LIB_DIR="$build_dir" \
  DUNE_PROFILE=android \
  LOGSEQ_CHAT_SQLITE_LIB_DIR="$build_dir" \
  "$repo_root/scripts/build-mobile-ocaml.sh" "$target_prefix" "$dune_context")

for source in logseq_chat_crypto_android.c logseq_chat_https_android.c; do
  "$ndk_bin/clang" \
    --target="$target" \
    -fPIC \
    -I "$ocaml_lib" \
    -c "$repo_root/core/$source" \
    -o "${source%.c}.o"
done

"$ndk_bin/clang" \
  --target="$target" \
  -shared \
  -Wl,--no-undefined \
  -Wl,-soname,liblogseq_chat_core.so \
  -o "$library" \
  "$runtime_object" \
  logseq_chat_crypto_android.o \
  logseq_chat_https_android.o \
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
