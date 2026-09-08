#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ios_device_config=${LOGSEQ_CHAT_IOS_CONFIG:-$repo_root/.logseq-chat-ios-device.env}
[[ -f $ios_device_config ]] && source "$ios_device_config"

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
https_object="$core_build_dir/logseq_chat_https_darwin.o"
crypto_object="$core_build_dir/logseq_chat_crypto_darwin.o"
app_dir="$repo_root/.build/LogseqChat-device.app"
profile_plist="$core_build_dir/profile.plist"
entitlements="$core_build_dir/entitlements.plist"

die() {
  echo "error: $*" >&2
  exit 1
}

prune_stale_swift_resource_bundles() {
  [[ -d $swift_build_dir ]] || return 0
  [[ $swift_build_dir == "$swift_scratch_dir/"* && $swift_build_dir != "$swift_scratch_dir" ]] \
    || die "refusing to prune an invalid Swift build directory: $swift_build_dir"
  while IFS= read -r -d '' bundle; do
    rm -rf -- "$bundle"
  done < <(find "$swift_build_dir" -mindepth 1 -maxdepth 1 -type d -name '*.bundle' -print0)
}

[[ $build_configuration == debug || $build_configuration == release ]] \
  || die "unsupported iOS build configuration: $build_configuration"

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
[[ -n $signing_keychain ]] && codesign_keychain_args=(--keychain "$signing_keychain")
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

ocaml_lib="$target_prefix/lib/ocaml"
clang=$(xcrun --sdk iphoneos --find clang)
core_object=$(LOGSEQ_CHAT_SQLITE_LIB_DIR="$sdk_path/usr/lib" \
  LOGSEQ_CHAT_SQLITE_LINK_FILE="$sdk_path/usr/lib/libsqlite3.tbd" \
  "$repo_root/scripts/build-mobile-ocaml.sh" "$target_prefix" ios_device)

for source in logseq_chat_https_darwin.m logseq_chat_crypto_darwin.m; do
  "$clang" \
    -target "$triple" \
    -isysroot "$sdk_path" \
    -fobjc-arc \
    -fPIC \
    -I "$ocaml_lib" \
    -c "$repo_root/core/$source" \
    -o "$core_build_dir/${source%.m}.o"
done

native_link_fingerprint=$(shasum -a 256 \
  "$core_object" "$https_object" "$crypto_object" "$ocaml_lib/libthreadsnat.a" \
  | shasum -a 256 | cut -d ' ' -f 1)
native_link_dir="$core_build_dir/native-link-inputs/$native_link_fingerprint"
fingerprinted_core_object="$native_link_dir/logseq_chat_runtime.o"
mkdir -p "$native_link_dir"
[[ -s $fingerprinted_core_object ]] || cp "$core_object" "$fingerprinted_core_object"
native_link_inputs="$fingerprinted_core_object:$https_object:$crypto_object:$ocaml_lib/libthreadsnat.a"

prune_stale_swift_resource_bundles
LOGSEQ_CHAT_NATIVE_LINK_INPUTS="$native_link_inputs" \
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
  [[ -d $bundle ]] || continue
  cp -R "$bundle" "$app_dir/"
done

logseq_resource_bundle="$app_dir/logseq-chat_LogseqChat.bundle"
if [[ -d $logseq_resource_bundle ]]; then
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
plutil -replace application-identifier -string "$expected_app_id" "$entitlements"
codesign "${codesign_keychain_args[@]}" --force --sign "$signing_identity" --timestamp=none \
  --entitlements "$entitlements" "$app_dir"
codesign --verify --deep --strict "$app_dir"

echo "$app_dir"
