#!/usr/bin/env bash

set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ocaml_demo_root=${LOGSEQ_CHAT_OCAML_DEMO_ROOT:-/Users/tiensonqin/Codes/projects/ocaml-demo}
ocaml_version=${LOGSEQ_CHAT_IOS_OCAML_VERSION:-5.5.0}
deployment_target=${LOGSEQ_CHAT_IOS_DEPLOYMENT_TARGET:-17.0}
team_id=${LOGSEQ_CHAT_SIMULATOR_TEAM_ID:-3K44EUN829}
sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
triple="arm64-apple-ios${deployment_target}-simulator"
target_prefix="$ocaml_demo_root/_build/ios-toolchain/$triple-$ocaml_version"
swift_build_dir="$repo_root/.build/arm64-apple-ios-simulator/debug"
core_build_dir="$repo_root/_build/ios-core/simulator"
core_object="$core_build_dir/logseq_chat_runtime.o"
ffi_object="$core_build_dir/logseq_chat_core_ffi.o"
https_object="$core_build_dir/logseq_chat_https_darwin.o"
sqlite_object="$core_build_dir/datascript_sqlite_stubs.o"
graph_store_object="$core_build_dir/logseq_chat_graph_store_stubs.o"
simulator_entitlements="$core_build_dir/simulator-entitlements.plist"
signature_entitlements="$core_build_dir/simulator-signature-entitlements.plist"
app_dir="$repo_root/.build/LogseqChat.app"
xcode_app_dir="$repo_root/.build/Darwin/DerivedData/Build/Products/Debug-iphonesimulator/LogseqChat.app"

if [[ ! -x $target_prefix/bin/ocamlopt.opt ]]; then
  "$ocaml_demo_root/scripts/bootstrap-ios-ocaml.sh" >/dev/null
fi

ocamlopt="$target_prefix/bin/ocamlopt.opt"
ocaml_lib="$target_prefix/lib/ocaml"
clang=$(xcrun --sdk iphonesimulator --find clang)

mkdir -p "$core_build_dir"
plutil -create xml1 "$simulator_entitlements"
plutil -insert application-identifier -string "${team_id}.com.logseq.chat" "$simulator_entitlements"
plutil -insert keychain-access-groups -json "[\"${team_id}.com.logseq.chat\"]" "$simulator_entitlements"
plutil -create xml1 "$signature_entitlements"
"$repo_root/scripts/build-mobile-ocaml-deps.sh" \
  "$target_prefix" \
  "$core_build_dir"
dependency_dir="$core_build_dir/mobile-ocaml-deps"
dependency_objects=()
while IFS= read -r object; do
  dependency_objects+=("$object")
done <"$dependency_dir/link-objects.txt"
sqlite_stub_source=$(<"$dependency_dir/sqlite-stub-source.txt")

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
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_entity_sync.cmx \
  "$repo_root/core/logseq_chat_entity_sync.ml"
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
  logseq_chat_entity_sync.cmx \
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

"$clang" \
  -target "$triple" \
  -isysroot "$sdk_path" \
  -fPIC \
  -I "$ocaml_lib" \
  -c "$repo_root/core/logseq_chat_core_ffi.c" \
  -o "$ffi_object"

"$clang" \
  -target "$triple" \
  -isysroot "$sdk_path" \
  -fobjc-arc \
  -fPIC \
  -I "$ocaml_lib" \
  -c "$repo_root/core/logseq_chat_https_darwin.m" \
  -o "$https_object"

"$clang" \
  -target "$triple" \
  -isysroot "$sdk_path" \
  -fPIC \
  -I "$ocaml_lib" \
  -c "$sqlite_stub_source" \
  -o "$sqlite_object"

"$clang" \
  -target "$triple" \
  -isysroot "$sdk_path" \
  -fPIC \
  -I "$ocaml_lib" \
  -c "$repo_root/core/logseq_chat_graph_store_stubs.c" \
  -o "$graph_store_object"

native_link_fingerprint=$(
  shasum -a 256 \
    "$core_object" \
    "$ffi_object" \
    "$https_object" \
    "$sqlite_object" \
    "$graph_store_object" \
    | shasum -a 256 \
    | cut -d ' ' -f 1
)
native_link_dir="$core_build_dir/native-link-inputs/$native_link_fingerprint"
mkdir -p "$native_link_dir"
cp "$core_object" "$native_link_dir/logseq_chat_runtime.o"
fingerprinted_native_link_inputs="$native_link_dir/logseq_chat_runtime.o:$ffi_object:$https_object:$sqlite_object:$graph_store_object:$ocaml_lib/libthreadsnat.a"

LOGSEQ_CHAT_NATIVE_LINK_INPUTS="$fingerprinted_native_link_inputs" \
LOGSEQ_CHAT_SIMULATOR_ENTITLEMENTS="$simulator_entitlements" \
swift build \
  --disable-keychain \
  --package-path "$repo_root" \
  --product LogseqChatShell \
  --triple "$triple" \
  --sdk "$sdk_path"

if [[ -d $app_dir ]]; then
  chmod -R u+w "$app_dir"
  rm -rf "$app_dir"
fi
mkdir -p "$app_dir"
if [[ -f "$xcode_app_dir/Info.plist" ]]; then
  cp "$xcode_app_dir/Info.plist" "$app_dir/Info.plist"
else
  cp "$repo_root/Darwin/Info.plist" "$app_dir/Info.plist"
  "$repo_root/scripts/configure-ios-info-plist.sh" "$app_dir/Info.plist" "com.logseq.chat" "$deployment_target" "iPhoneSimulator"
fi
cp "$swift_build_dir/LogseqChatShell" "$app_dir/LogseqChat"

for bundle in "$swift_build_dir"/*.bundle; do
  [[ -d "$bundle" ]] || continue
  cp -R "$bundle" "$app_dir/"
done

logseq_resource_bundle="$app_dir/logseq-chat_LogseqChat.bundle"
if [[ -d "$logseq_resource_bundle" ]]; then
  xcrun actool \
    --compile "$logseq_resource_bundle" \
    --platform iphonesimulator \
    --minimum-deployment-target "$deployment_target" \
    --target-device iphone \
    --target-device ipad \
    "$repo_root/Sources/LogseqChat/Resources/Icons.xcassets" \
    "$repo_root/Sources/LogseqChat/Resources/Module.xcassets" >/dev/null
fi

codesign --force --sign - --entitlements "$signature_entitlements" --timestamp=none --generate-entitlement-der "$app_dir"

echo "$app_dir"
