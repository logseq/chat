#!/usr/bin/env bash

set -euo pipefail

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

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
toolchain_root=${LOGSEQ_CHAT_APPLE_TOOLCHAIN_ROOT:-$repo_root/_build/apple-toolchains}
ocaml_version=${LOGSEQ_CHAT_IOS_OCAML_VERSION:-5.5.0}
deployment_target=${LOGSEQ_CHAT_IOS_DEPLOYMENT_TARGET:-17.0}
team_id=${LOGSEQ_CHAT_SIMULATOR_TEAM_ID:-3K44EUN829}
configuration=${LOGSEQ_CHAT_IOS_CONFIGURATION:-debug}
[[ $configuration == debug || $configuration == release ]] \
  || die "LOGSEQ_CHAT_IOS_CONFIGURATION must be debug or release"
[[ $configuration == release ]] && configuration_name=Release || configuration_name=Debug

sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
triple="arm64-apple-ios${deployment_target}-simulator"
target_prefix=${LOGSEQ_CHAT_IOS_TOOLCHAIN_PREFIX:-$toolchain_root/ios/$triple-$ocaml_version}
swift_scratch_dir=${LOGSEQ_CHAT_IOS_SWIFT_SCRATCH_PATH:-$repo_root/.build}
swift_build_dir="$swift_scratch_dir/arm64-apple-ios-simulator/$configuration"
core_build_dir="$repo_root/_build/ios-core/simulator"
https_object="$core_build_dir/logseq_chat_https_darwin.o"
crypto_object="$core_build_dir/logseq_chat_crypto_darwin.o"
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

ocaml_lib="$target_prefix/lib/ocaml"
clang=$(xcrun --sdk iphonesimulator --find clang)
mkdir -p "$core_build_dir"

plutil -create xml1 "$simulator_entitlements"
plutil -insert application-identifier -string "${team_id}.com.logseq.chat" "$simulator_entitlements"
plutil -insert keychain-access-groups -json "[\"${team_id}.com.logseq.chat\"]" "$simulator_entitlements"
plutil -insert 'com\.apple\.security\.application-groups' -json '["group.com.logseq.chat"]' "$simulator_entitlements"
plutil -create xml1 "$signature_entitlements"
plutil -insert 'com\.apple\.security\.application-groups' -json '["group.com.logseq.chat"]' "$signature_entitlements"

core_object=$(LOGSEQ_CHAT_SQLITE_LIB_DIR="$sdk_path/usr/lib" \
  "$repo_root/scripts/build-mobile-ocaml.sh" "$target_prefix")

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
  [[ -d $bundle ]] || continue
  cp -R "$bundle" "$app_dir/"
done

plugins_dir="$app_dir/PlugIns"
mkdir -p "$plugins_dir"
for extension in LogseqChatShareExtension LogseqChatWidgets; do
  extension_product="$extension_build_dir/$extension.appex"
  [[ -d $extension_product ]] || die "missing simulator extension: $extension_product"
  cp -R "$extension_product" "$plugins_dir/"
done
codesign --force --sign - --entitlements "$repo_root/Darwin/ShareExtension/ShareExtension.entitlements" \
  --timestamp=none --generate-entitlement-der "$plugins_dir/LogseqChatShareExtension.appex"
codesign --force --sign - --timestamp=none --generate-entitlement-der \
  "$plugins_dir/LogseqChatWidgets.appex"

logseq_resource_bundle="$app_dir/logseq-chat_LogseqChat.bundle"
if [[ -d $logseq_resource_bundle ]]; then
  xcrun actool \
    --compile "$logseq_resource_bundle" \
    --platform iphonesimulator \
    --minimum-deployment-target "$deployment_target" \
    --target-device iphone \
    --target-device ipad \
    "$repo_root/Sources/LogseqChat/Resources/Icons.xcassets" \
    "$repo_root/Sources/LogseqChat/Resources/Module.xcassets" >/dev/null
fi

codesign --force --sign - --entitlements "$signature_entitlements" \
  --timestamp=none --generate-entitlement-der "$app_dir"

echo "$app_dir"
