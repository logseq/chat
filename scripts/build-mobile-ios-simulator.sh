#!/usr/bin/env bash

set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
toolchain_root=${LOGSEQ_CHAT_APPLE_TOOLCHAIN_ROOT:-$repo_root/_build/apple-toolchains}
ocaml_version=${LOGSEQ_CHAT_IOS_OCAML_VERSION:-5.5.0}
deployment_target=${LOGSEQ_CHAT_IOS_DEPLOYMENT_TARGET:-17.0}
team_id=${LOGSEQ_CHAT_SIMULATOR_TEAM_ID:-3K44EUN829}
configuration=${LOGSEQ_CHAT_IOS_CONFIGURATION:-debug}
[[ $configuration == debug || $configuration == release ]] \
  || die "LOGSEQ_CHAT_IOS_CONFIGURATION must be debug or release"
if [[ $configuration == release ]]; then
  configuration_name=Release
else
  configuration_name=Debug
fi
sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
triple="arm64-apple-ios${deployment_target}-simulator"
target_prefix=${LOGSEQ_CHAT_IOS_TOOLCHAIN_PREFIX:-$toolchain_root/ios/$triple-$ocaml_version}
swift_build_dir="$repo_root/.build/arm64-apple-ios-simulator/$configuration"
core_build_dir="$repo_root/_build/ios-core/simulator"
core_object="$core_build_dir/logseq_chat_runtime.o"
ffi_object="$core_build_dir/logseq_chat_core_ffi.o"
https_object="$core_build_dir/logseq_chat_https_darwin.o"
crypto_object="$core_build_dir/logseq_chat_crypto_darwin.o"
sqlite_object="$core_build_dir/datascript_sqlite_stubs.o"
graph_store_object="$core_build_dir/logseq_chat_graph_store_stubs.o"
simulator_entitlements="$core_build_dir/simulator-entitlements.plist"
signature_entitlements="$core_build_dir/simulator-signature-entitlements.plist"
extension_build_dir="$core_build_dir/extensions/$configuration_name"
app_dir="$repo_root/.build/LogseqChat.app"
xcode_app_dir="$repo_root/.build/Darwin/DerivedData/Build/Products/$configuration_name-iphonesimulator/LogseqChat.app"

if [[ ${LOGSEQ_CHAT_IOS_PRINT_BUILD_SETTINGS:-0} == 1 ]]; then
  echo "configuration=$configuration ocaml-version=$ocaml_version target=$triple toolchain-root=$toolchain_root toolchain-prefix=$target_prefix"
  exit 0
fi

if [[ ! -x $target_prefix/bin/ocamlopt.opt ]]; then
  "$repo_root/scripts/bootstrap-ios-ocaml.sh" simulator >/dev/null
fi

ocamlopt="$target_prefix/bin/ocamlopt.opt"
ocaml_lib="$target_prefix/lib/ocaml"
clang=$(xcrun --sdk iphonesimulator --find clang)

mkdir -p "$core_build_dir"
plutil -create xml1 "$simulator_entitlements"
plutil -insert application-identifier -string "${team_id}.com.logseq.chat" "$simulator_entitlements"
plutil -insert keychain-access-groups -json "[\"${team_id}.com.logseq.chat\"]" "$simulator_entitlements"
plutil -insert 'com\.apple\.security\.application-groups' -json '["group.com.logseq.chat"]' "$simulator_entitlements"
plutil -create xml1 "$signature_entitlements"
plutil -insert 'com\.apple\.security\.application-groups' -json '["group.com.logseq.chat"]' "$signature_entitlements"
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
  && -s $crypto_object \
  && -s $sqlite_object \
  && -s $graph_store_object ]]; then
  echo "OCaml core cache hit: $core_build_dir"
else
  cd "$core_build_dir"

"$ocamlopt" -I "$dependency_dir" -c -o logseq_chat_model.cmx \
  "$repo_root/core/logseq_chat_model.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_markup.cmx \
  "$repo_root/core/logseq_chat_markup.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_edn.cmx \
  "$repo_root/core/logseq_chat_edn.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_e2ee.cmx \
  "$repo_root/core/logseq_chat_e2ee.ml"
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
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_datascript_value.cmx \
  "$repo_root/core/logseq_chat_datascript_value.ml"
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
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_e2ee_keyring.cmx \
  "$repo_root/core/logseq_chat_e2ee_keyring.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_platform_crypto.cmx \
  "$repo_root/core/logseq_chat_platform_crypto.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_http.cmx \
  "$repo_root/core/logseq_chat_http.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_fractional_order.cmx \
  "$repo_root/core/logseq_chat_fractional_order.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_outliner.cmx \
  "$repo_root/core/logseq_chat_outliner.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_pending_ops.cmx \
  "$repo_root/core/logseq_chat_pending_ops.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_outliner_state.cmx \
  "$repo_root/core/logseq_chat_outliner_state.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_outliner_effects.cmx \
  "$repo_root/core/logseq_chat_outliner_effects.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_rpc.cmx \
  "$repo_root/core/logseq_chat_rpc.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_logseq_storage_codec.cmx \
  "$repo_root/core/logseq_chat_logseq_storage_codec.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_graph_store.cmx \
  "$repo_root/core/logseq_chat_graph_store.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_pending_projection.cmx \
  "$repo_root/core/logseq_chat_pending_projection.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_sync_tx.cmx \
  "$repo_root/core/logseq_chat_sync_tx.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_graph_runtime.cmx \
  "$repo_root/core/logseq_chat_graph_runtime.ml"
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
  logseq_chat_markup.cmx \
  logseq_chat_edn.cmx \
  logseq_chat_e2ee.cmx \
  logseq_chat_sync_protocol.cmx \
  logseq_chat_sync_state.cmx \
  logseq_chat_sync_checkpoint.cmx \
  logseq_chat_snapshot.cmx \
  logseq_chat_entity_sync.cmx \
  logseq_chat_datascript_value.cmx \
  logseq_chat_ref_text.cmx \
  logseq_chat_graph_read.cmx \
  logseq_chat_flashcards.cmx \
  logseq_chat_search_index.cmx \
  logseq_chat_sse.cmx \
  logseq_chat_api.cmx \
  logseq_chat_e2ee_keyring.cmx \
  logseq_chat_platform_crypto.cmx \
  logseq_chat_http.cmx \
  logseq_chat_fractional_order.cmx \
  logseq_chat_outliner.cmx \
  logseq_chat_pending_ops.cmx \
  logseq_chat_outliner_state.cmx \
  logseq_chat_outliner_effects.cmx \
  logseq_chat_rpc.cmx \
  logseq_chat_logseq_storage_codec.cmx \
  logseq_chat_graph_store.cmx \
  logseq_chat_pending_projection.cmx \
  logseq_chat_sync_tx.cmx \
  logseq_chat_graph_runtime.cmx \
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
  -fobjc-arc \
  -fPIC \
  -I "$ocaml_lib" \
  -c "$repo_root/core/logseq_chat_crypto_darwin.m" \
  -o "$crypto_object"

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
  printf '%s\n' "$core_fingerprint" >"$core_cache_stamp"
fi

native_link_fingerprint=$(
  shasum -a 256 \
    "$core_object" \
    "$ffi_object" \
    "$https_object" \
    "$crypto_object" \
    "$sqlite_object" \
    "$graph_store_object" \
    | shasum -a 256 \
    | cut -d ' ' -f 1
)
native_link_dir="$core_build_dir/native-link-inputs/$native_link_fingerprint"
mkdir -p "$native_link_dir"
cp "$core_object" "$native_link_dir/logseq_chat_runtime.o"
fingerprinted_native_link_inputs="$native_link_dir/logseq_chat_runtime.o:$ffi_object:$https_object:$crypto_object:$sqlite_object:$graph_store_object:$ocaml_lib/libthreadsnat.a"

LOGSEQ_CHAT_NATIVE_LINK_INPUTS="$fingerprinted_native_link_inputs" \
LOGSEQ_CHAT_SIMULATOR_ENTITLEMENTS="$simulator_entitlements" \
swift build \
  --configuration "$configuration" \
  --disable-keychain \
  --package-path "$repo_root" \
  --product LogseqChatShell \
  --triple "$triple" \
  --sdk "$sdk_path"

xcodebuild \
  -project "$repo_root/Darwin/LogseqChat.xcodeproj" \
  -target LogseqChatShareExtension \
  -target LogseqChatWidgets \
  -configuration "$configuration_name" \
  -sdk iphonesimulator \
  -arch arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CONFIGURATION_BUILD_DIR="$extension_build_dir" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

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

plugins_dir="$app_dir/PlugIns"
mkdir -p "$plugins_dir"
for extension in LogseqChatShareExtension LogseqChatWidgets; do
  extension_product="$extension_build_dir/$extension.appex"
  [[ -d "$extension_product" ]] || die "missing simulator extension: $extension_product"
  cp -R "$extension_product" "$plugins_dir/"
done
codesign \
  --force \
  --sign - \
  --entitlements "$repo_root/Darwin/ShareExtension/ShareExtension.entitlements" \
  --timestamp=none \
  --generate-entitlement-der \
  "$plugins_dir/LogseqChatShareExtension.appex"
codesign \
  --force \
  --sign - \
  --timestamp=none \
  --generate-entitlement-der \
  "$plugins_dir/LogseqChatWidgets.appex"

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
