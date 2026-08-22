#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ios_device_config=${LOGSEQ_CHAT_IOS_CONFIG:-$repo_root/.logseq-chat-ios-device.env}
if [[ -f $ios_device_config ]]; then
  source "$ios_device_config"
fi
toolchain_root=${LOGSEQ_CHAT_APPLE_TOOLCHAIN_ROOT:-$repo_root/_build/apple-toolchains}
ocaml_version=${LOGSEQ_CHAT_IOS_OCAML_VERSION:-5.5.0}
deployment_target=${LOGSEQ_CHAT_IOS_DEPLOYMENT_TARGET:-17.0}
bundle_id=${LOGSEQ_CHAT_IOS_BUNDLE_ID:-com.logseq.chat}
build_configuration=${LOGSEQ_CHAT_IOS_BUILD_CONFIGURATION:-debug}
profile=${LOGSEQ_CHAT_IOS_PROFILE:-}
signing_identity=${LOGSEQ_CHAT_IOS_SIGNING_IDENTITY:-Apple Development}
signing_keychain=${LOGSEQ_CHAT_IOS_KEYCHAIN:-}
signing_keychain_password=${LOGSEQ_CHAT_IOS_KEYCHAIN_PASSWORD-}
sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
triple="arm64-apple-ios${deployment_target}"
target_prefix=${LOGSEQ_CHAT_IOS_TOOLCHAIN_PREFIX:-$toolchain_root/ios/$triple-$ocaml_version}
swift_scratch_dir=${LOGSEQ_CHAT_IOS_SWIFT_SCRATCH_PATH:-$repo_root/.build/ios-device}
swift_build_dir="$swift_scratch_dir/arm64-apple-ios/$build_configuration"
core_build_dir="$repo_root/_build/ios-core/device"
core_object="$core_build_dir/logseq_chat_runtime.o"
ffi_object="$core_build_dir/logseq_chat_core_ffi.o"
https_object="$core_build_dir/logseq_chat_https_darwin.o"
crypto_object="$core_build_dir/logseq_chat_crypto_darwin.o"
sqlite_object="$core_build_dir/datascript_sqlite_stubs.o"
graph_store_object="$core_build_dir/logseq_chat_graph_store_stubs.o"
app_dir="$repo_root/.build/LogseqChat-device.app"
profile_plist="$core_build_dir/profile.plist"
entitlements="$core_build_dir/entitlements.plist"

die() {
  echo "error: $*" >&2
  exit 1
}

case "$build_configuration" in
  debug)
    ;;
  release)
    ;;
  *)
    die "unsupported iOS build configuration: $build_configuration"
    ;;
esac

if [[ ${LOGSEQ_CHAT_IOS_PRINT_BUILD_SETTINGS:-0} == 1 ]]; then
  echo "configuration=$build_configuration swift-build-dir=$swift_build_dir ocaml-version=$ocaml_version target=$triple toolchain-root=$toolchain_root toolchain-prefix=$target_prefix profile=$profile signing-identity=$signing_identity"
  exit 0
fi

[[ $bundle_id != "com.logseq.logseq" ]] || die "refusing to build the production Logseq bundle id"
[[ -n $profile ]] || die "set LOGSEQ_CHAT_IOS_PROFILE to a development provisioning profile for $bundle_id"
[[ -f $profile ]] || die "provisioning profile was not found: $profile"
if [[ -n $signing_keychain && ! -f $signing_keychain ]]; then
  die "signing keychain was not found: $signing_keychain"
fi
codesign_keychain_args=()
if [[ -n $signing_keychain ]]; then
  codesign_keychain_args=(--keychain "$signing_keychain")
fi

original_keychain_search_list=()
restore_keychain_search_list() {
  local exit_status=$?
  if ((${#original_keychain_search_list[@]} > 0)); then
    security list-keychains -d user -s "${original_keychain_search_list[@]}" >/dev/null || true
  fi
  return "$exit_status"
}

if [[ -n $signing_keychain ]]; then
  while IFS='"' read -r _ keychain_path _; do
    [[ -n $keychain_path ]] && original_keychain_search_list+=("$keychain_path")
  done < <(security list-keychains -d user)
  security list-keychains -d user -s \
    "${original_keychain_search_list[@]}" "$signing_keychain"
  trap restore_keychain_search_list EXIT
  if [[ ${LOGSEQ_CHAT_IOS_KEYCHAIN_PASSWORD+x} == x ]]; then
    security unlock-keychain -p "$signing_keychain_password" "$signing_keychain"
  fi
fi

mkdir -p "$core_build_dir"
security cms -D -i "$profile" >"$profile_plist"
profile_app_id=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:application-identifier" "$profile_plist")
team_id=$(/usr/libexec/PlistBuddy -c "Print :TeamIdentifier:0" "$profile_plist")
expected_app_id="$team_id.$bundle_id"
if [[ $profile_app_id != "$expected_app_id" && $profile_app_id != "$team_id.*" ]]; then
  die "profile app id is $profile_app_id, expected $expected_app_id or $team_id.*"
fi

if [[ ! -x $target_prefix/bin/ocamlopt.opt ]]; then
  "$repo_root/scripts/bootstrap-ios-ocaml.sh" device >/dev/null
fi

ocamlopt="$target_prefix/bin/ocamlopt.opt"
ocaml_lib="$target_prefix/lib/ocaml"
clang=$(xcrun --sdk iphoneos --find clang)

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
    "$ocaml_lib/libthreadsnat.a" \
    | shasum -a 256 \
    | cut -d ' ' -f 1
)
native_link_dir="$core_build_dir/native-link-inputs/$native_link_fingerprint"
fingerprinted_core_object="$native_link_dir/logseq_chat_runtime.o"
mkdir -p "$native_link_dir"
if [[ ! -s $fingerprinted_core_object ]]; then
  cp "$core_object" "$fingerprinted_core_object"
fi
fingerprinted_native_link_inputs="$fingerprinted_core_object:$ffi_object:$https_object:$crypto_object:$sqlite_object:$graph_store_object:$ocaml_lib/libthreadsnat.a"

LOGSEQ_CHAT_NATIVE_LINK_INPUTS="$fingerprinted_native_link_inputs" \
swift build \
  -c "$build_configuration" \
  --scratch-path "$swift_scratch_dir" \
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
cp "$repo_root/Darwin/Info.plist" "$app_dir/Info.plist"
cp "$profile" "$app_dir/embedded.mobileprovision"
"$repo_root/scripts/configure-ios-info-plist.sh" "$app_dir/Info.plist" "$bundle_id" "$deployment_target" "iPhoneOS"
cp "$swift_build_dir/LogseqChatShell" "$app_dir/LogseqChat"

for bundle in "$swift_build_dir"/*.bundle; do
  [[ -d "$bundle" ]] || continue
  cp -R "$bundle" "$app_dir/"
done

logseq_resource_bundle="$app_dir/logseq-chat_LogseqChat.bundle"
if [[ -d "$logseq_resource_bundle" ]]; then
  xcrun actool \
    --compile "$logseq_resource_bundle" \
    --platform iphoneos \
    --minimum-deployment-target "$deployment_target" \
    --target-device iphone \
    --target-device ipad \
    "$repo_root/Sources/LogseqChat/Resources/Icons.xcassets" \
    "$repo_root/Sources/LogseqChat/Resources/Module.xcassets" >/dev/null
fi

plutil -extract Entitlements xml1 -o "$entitlements" "$profile_plist"
plutil -replace application-identifier \
  -string "$expected_app_id" \
  "$entitlements"

codesign "${codesign_keychain_args[@]}" --force --sign "$signing_identity" --timestamp=none \
  --entitlements "$entitlements" \
  "$app_dir"
codesign --verify --deep --strict "$app_dir"

echo "$app_dir"
