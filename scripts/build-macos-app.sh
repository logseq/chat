#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
toolchain_root=${LOGSEQ_CHAT_APPLE_TOOLCHAIN_ROOT:-$repo_root/_build/apple-toolchains}
ocaml_version=${LOGSEQ_CHAT_MACOS_OCAML_VERSION:-5.5.0}
deployment_target=${LOGSEQ_CHAT_MACOS_DEPLOYMENT_TARGET:-14.0}
configuration=${LOGSEQ_CHAT_MACOS_CONFIGURATION:-release}
bundle_id=${LOGSEQ_CHAT_MACOS_BUNDLE_ID:-com.logseq.chat}
toolchain_name="host-$ocaml_version-macos$deployment_target"
target_prefix=${LOGSEQ_CHAT_MACOS_TOOLCHAIN_PREFIX:-$toolchain_root/macos/$toolchain_name}
triple="arm64-apple-macosx$deployment_target"
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
core_build_dir="$repo_root/_build/macos-core"
core_object="$core_build_dir/logseq_chat_runtime.o"
ffi_object="$core_build_dir/logseq_chat_core_ffi.o"
https_object="$core_build_dir/logseq_chat_https_darwin.o"
sqlite_object="$core_build_dir/datascript_sqlite_stubs.o"
graph_store_object="$core_build_dir/logseq_chat_graph_store_stubs.o"
app_dir="$repo_root/.build/macos/LogseqChat.app"
contents_dir="$app_dir/Contents"
frameworks_dir="$contents_dir/Frameworks"
resources_dir="$contents_dir/Resources"

die() {
  echo "error: $*" >&2
  exit 1
}

case "$configuration" in
  debug | release)
    ;;
  *)
    die "unsupported macOS build configuration: $configuration"
    ;;
esac

if [[ ${LOGSEQ_CHAT_MACOS_PRINT_BUILD_SETTINGS:-0} == 1 ]]; then
  echo "configuration=$configuration ocaml-version=$ocaml_version target=$triple toolchain=$toolchain_name toolchain-root=$toolchain_root toolchain-prefix=$target_prefix"
  exit 0
fi

[[ $(uname -s) == Darwin ]] || die "the macOS app requires macOS"
if [[ ! -x $target_prefix/bin/ocamlopt.opt ]]; then
  "$repo_root/scripts/bootstrap-macos-ocaml.sh" >/dev/null
fi

actual_ocaml_version=$($target_prefix/bin/ocamlopt.opt -version)
[[ $actual_ocaml_version == "$ocaml_version" ]] \
  || die "OCaml compiler version is $actual_ocaml_version, expected $ocaml_version"

export MACOSX_DEPLOYMENT_TARGET="$deployment_target"

ocamlopt="$target_prefix/bin/ocamlopt.opt"
ocaml_lib="$target_prefix/lib/ocaml"
clang=$(xcrun --sdk macosx --find clang)

mkdir -p "$core_build_dir"
"$repo_root/scripts/build-mobile-ocaml-deps.sh" \
  "$target_prefix" \
  "$core_build_dir"
dependency_dir="$core_build_dir/mobile-ocaml-deps"
dependency_objects=()
while IFS= read -r object; do
  dependency_objects+=("$object")
done <"$dependency_dir/link-objects.txt"
sqlite_stub_source=$(<"$dependency_dir/sqlite-stub-source.txt")
core_fingerprint=$("$repo_root/scripts/apple-core-fingerprint.sh" \
  "$target_prefix" "$triple" "$sdk_path" "$dependency_dir/.build-fingerprint")
core_cache_stamp="$core_build_dir/.core-build-fingerprint"

if [[ -f $core_cache_stamp \
  && $(<"$core_cache_stamp") == "$core_fingerprint" \
  && -s $core_object \
  && -s $ffi_object \
  && -s $https_object \
  && -s $sqlite_object \
  && -s $graph_store_object ]]; then
  echo "OCaml core cache hit: $core_build_dir"
else
  cd "$core_build_dir"

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
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_logseq_storage_codec.cmx \
  "$repo_root/core/logseq_chat_logseq_storage_codec.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_graph_bootstrap_data.cmx \
  "$repo_root/core/logseq_chat_graph_bootstrap_data.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_graph_bootstrap.cmx \
  "$repo_root/core/logseq_chat_graph_bootstrap.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_entity_sync.cmx \
  "$repo_root/core/logseq_chat_entity_sync.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_ref_text.cmx \
  "$repo_root/core/logseq_chat_ref_text.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_graph_read.cmx \
  "$repo_root/core/logseq_chat_graph_read.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_flashcards.cmx \
  "$repo_root/core/logseq_chat_flashcards.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_search_index.cmx \
  "$repo_root/core/logseq_chat_search_index.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_sse.cmx \
  "$repo_root/core/logseq_chat_sse.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_api.cmx \
  "$repo_root/core/logseq_chat_api.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_http.cmx \
  "$repo_root/core/logseq_chat_http.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_rpc.cmx \
  "$repo_root/core/logseq_chat_rpc.ml"
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
  -output-complete-obj \
  -linkall \
  -o "$core_object" \
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
  logseq_chat_logseq_storage_codec.cmx \
  logseq_chat_graph_bootstrap_data.cmx \
  logseq_chat_graph_bootstrap.cmx \
  logseq_chat_entity_sync.cmx \
  logseq_chat_ref_text.cmx \
  logseq_chat_graph_read.cmx \
  logseq_chat_flashcards.cmx \
  logseq_chat_search_index.cmx \
  logseq_chat_sse.cmx \
  logseq_chat_api.cmx \
  logseq_chat_http.cmx \
  logseq_chat_rpc.cmx \
  logseq_chat_graph_store.cmx \
  logseq_chat_sync_session.cmx \
  logseq_chat_sqlite.cmx \
  logseq_chat_mobile_entry.cmx

"$clang" -target "$triple" -isysroot "$sdk_path" -fPIC \
  -I "$ocaml_lib" \
  -c "$repo_root/core/logseq_chat_core_ffi.c" \
  -o "$ffi_object"

"$clang" -target "$triple" -isysroot "$sdk_path" -fobjc-arc -fPIC \
  -I "$ocaml_lib" \
  -c "$repo_root/core/logseq_chat_https_darwin.m" \
  -o "$https_object"

"$clang" -target "$triple" -isysroot "$sdk_path" -fPIC \
  -I "$ocaml_lib" \
  -c "$sqlite_stub_source" \
  -o "$sqlite_object"

"$clang" -target "$triple" -isysroot "$sdk_path" -fPIC \
  -I "$ocaml_lib" \
  -c "$repo_root/core/logseq_chat_graph_store_stubs.c" \
  -o "$graph_store_object"
  printf '%s\n' "$core_fingerprint" >"$core_cache_stamp"
fi

cd "$repo_root"
swift build \
  -c "$configuration" \
  --disable-keychain \
  --triple "$triple" \
  --sdk "$sdk_path" \
  -Xswiftc -DLOGSEQ_CHAT_CORE \
  -Xlinker "$core_object" \
  -Xlinker "$ffi_object" \
  -Xlinker "$https_object" \
  -Xlinker "$sqlite_object" \
  -Xlinker "$graph_store_object" \
  -Xlinker "$ocaml_lib/libthreadsnat.a" \
  -Xlinker -framework \
  -Xlinker Foundation \
  -Xlinker -lsqlite3

swift_build_dir=$(swift build \
  -c "$configuration" \
  --disable-keychain \
  --triple "$triple" \
  --sdk "$sdk_path" \
  --show-bin-path)

rm -rf "$app_dir"
mkdir -p "$contents_dir/MacOS" "$frameworks_dir" "$resources_dir"
cp "$repo_root/Darwin/Info.plist" "$contents_dir/Info.plist"
plutil -replace CFBundleExecutable -string LogseqChat "$contents_dir/Info.plist"
plutil -replace CFBundleIdentifier -string "$bundle_id" "$contents_dir/Info.plist"
plutil -replace CFBundlePackageType -string APPL "$contents_dir/Info.plist"
plutil -replace LSMinimumSystemVersion -string "$deployment_target" "$contents_dir/Info.plist"
plutil -remove UIDeviceFamily "$contents_dir/Info.plist" 2>/dev/null || true
plutil -remove UIBackgroundModes "$contents_dir/Info.plist" 2>/dev/null || true
plutil -remove BGTaskSchedulerPermittedIdentifiers "$contents_dir/Info.plist" 2>/dev/null || true

cp "$swift_build_dir/libLogseqChat.dylib" "$frameworks_dir/libLogseqChat.dylib"
for bundle in "$swift_build_dir"/*.bundle; do
  [[ -d $bundle ]] || continue
  cp -R "$bundle" "$resources_dir/"
done

logseq_chat_resource_bundle="$resources_dir/logseq-chat_LogseqChat.bundle"
[[ -d $logseq_chat_resource_bundle ]] \
  || die "LogseqChat resource bundle was not produced by SwiftPM"
logseq_chat_bundle_resources="$logseq_chat_resource_bundle/Contents/Resources"
mkdir -p "$logseq_chat_bundle_resources"
while IFS= read -r resource; do
  mv "$resource" "$logseq_chat_bundle_resources/"
done < <(find "$logseq_chat_resource_bundle" -mindepth 1 -maxdepth 1 \
  ! -name Contents ! -name Info.plist -print)
mv "$logseq_chat_resource_bundle/Info.plist" \
  "$logseq_chat_resource_bundle/Contents/Info.plist"
plutil -insert CFBundleIdentifier \
  -string "logseq-chat.LogseqChat.resources" \
  "$logseq_chat_resource_bundle/Contents/Info.plist"
plutil -insert CFBundleInfoDictionaryVersion \
  -string "6.0" \
  "$logseq_chat_resource_bundle/Contents/Info.plist"
plutil -insert CFBundleName \
  -string "logseq-chat_LogseqChat" \
  "$logseq_chat_resource_bundle/Contents/Info.plist"
plutil -insert CFBundlePackageType \
  -string BNDL \
  "$logseq_chat_resource_bundle/Contents/Info.plist"
xcrun actool \
  --compile "$logseq_chat_bundle_resources" \
  --platform macosx \
  --minimum-deployment-target "$deployment_target" \
  --target-device mac \
  --output-partial-info-plist "$core_build_dir/macos-assets.plist" \
  "$repo_root/Sources/LogseqChat/Resources/Icons.xcassets" \
  >/dev/null
[[ -f $logseq_chat_bundle_resources/Assets.car ]] \
  || die "failed to compile the macOS icon asset catalog"

cp "$swift_build_dir/LogseqChatShell" "$contents_dir/MacOS/LogseqChat"

codesign --force --sign - --timestamp=none "$frameworks_dir/libLogseqChat.dylib"
codesign --force --sign - --timestamp=none "$app_dir"
codesign --verify --deep --strict "$app_dir"

echo "$app_dir"
