#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ocaml_demo_root=${LOGSEQ_CHAT_OCAML_DEMO_ROOT:-/Users/tiensonqin/Codes/projects/ocaml-demo}
ocaml_version=${LOGSEQ_CHAT_IOS_OCAML_VERSION:-5.5.0}
deployment_target=${LOGSEQ_CHAT_IOS_DEPLOYMENT_TARGET:-17.0}
bundle_id=${LOGSEQ_CHAT_IOS_BUNDLE_ID:-com.logseq.chat}
build_configuration=${LOGSEQ_CHAT_IOS_BUILD_CONFIGURATION:-debug}
profile=${LOGSEQ_CHAT_IOS_PROFILE:-}
signing_identity=${LOGSEQ_CHAT_IOS_SIGNING_IDENTITY:-Apple Development}
sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
triple="arm64-apple-ios${deployment_target}"
target_prefix="$ocaml_demo_root/_build/ios-toolchain/$triple-$ocaml_version"
swift_build_dir="$repo_root/.build/arm64-apple-ios/$build_configuration"
core_build_dir="$repo_root/_build/ios-core/device"
core_object="$core_build_dir/logseq_chat_runtime.o"
ffi_object="$core_build_dir/logseq_chat_core_ffi.o"
https_object="$core_build_dir/logseq_chat_https_darwin.o"
sqlite_object="$core_build_dir/datascript_sqlite_stubs.o"
app_dir="$repo_root/.build/LogseqChat-device.app"
frameworks_dir="$app_dir/Frameworks"
profile_plist="$core_build_dir/profile.plist"
entitlements="$core_build_dir/entitlements.plist"

die() {
  echo "error: $*" >&2
  exit 1
}

case "$build_configuration" in
  debug)
    swift_shell_flags=(-Onone -g)
    ;;
  release)
    swift_shell_flags=(-O)
    ;;
  *)
    die "unsupported iOS build configuration: $build_configuration"
    ;;
esac

if [[ ${LOGSEQ_CHAT_IOS_PRINT_BUILD_SETTINGS:-0} == 1 ]]; then
  echo "configuration=$build_configuration swift-build-dir=$swift_build_dir"
  exit 0
fi

[[ $bundle_id != "com.logseq.logseq" ]] || die "refusing to build the production Logseq bundle id"
[[ -n $profile ]] || die "set LOGSEQ_CHAT_IOS_PROFILE to a development provisioning profile for $bundle_id"
[[ -f $profile ]] || die "provisioning profile was not found: $profile"

mkdir -p "$core_build_dir"
security cms -D -i "$profile" >"$profile_plist"
profile_app_id=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:application-identifier" "$profile_plist")
team_id=$(/usr/libexec/PlistBuddy -c "Print :TeamIdentifier:0" "$profile_plist")
expected_app_id="$team_id.$bundle_id"
if [[ $profile_app_id != "$expected_app_id" && $profile_app_id != "$team_id.*" ]]; then
  die "profile app id is $profile_app_id, expected $expected_app_id or $team_id.*"
fi

if [[ ! -x $target_prefix/bin/ocamlopt.opt ]]; then
  "$ocaml_demo_root/scripts/bootstrap-ios-device-ocaml.sh" >/dev/null
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

cd "$core_build_dir"

"$ocamlopt" -I "$dependency_dir" -c -o logseq_chat_model.cmx \
  "$repo_root/core/logseq_chat_model.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_api.cmx \
  "$repo_root/core/logseq_chat_api.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_http.cmx \
  "$repo_root/core/logseq_chat_http.ml"
"$ocamlopt" -I . -I "$dependency_dir" -c -o logseq_chat_rpc.cmx \
  "$repo_root/core/logseq_chat_rpc.ml"
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
  logseq_chat_api.cmx \
  logseq_chat_http.cmx \
  logseq_chat_rpc.cmx \
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

swift build \
  -c "$build_configuration" \
  --disable-keychain \
  --package-path "$repo_root" \
  --triple "$triple" \
  --sdk "$sdk_path" \
  -Xswiftc -DLOGSEQ_CHAT_CORE \
  -Xlinker "$core_object" \
  -Xlinker "$ffi_object" \
  -Xlinker "$https_object" \
  -Xlinker "$sqlite_object" \
  -Xlinker "$ocaml_lib/libthreadsnat.a" \
  -Xlinker -framework \
  -Xlinker Foundation \
  -Xlinker -lsqlite3

mkdir -p "$frameworks_dir"
cp "$repo_root/Darwin/Info.plist" "$app_dir/Info.plist"
cp "$profile" "$app_dir/embedded.mobileprovision"
"$repo_root/scripts/configure-ios-info-plist.sh" "$app_dir/Info.plist" "$bundle_id" "$deployment_target" "iPhoneOS"
cp "$swift_build_dir/libLogseqChat.dylib" "$frameworks_dir/libLogseqChat.dylib"

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

xcrun --sdk iphoneos swiftc \
  "${swift_shell_flags[@]}" \
  -parse-as-library \
  -module-name LogseqChatShell \
  -target "$triple" \
  -sdk "$sdk_path" \
  -I "$swift_build_dir/Modules" \
  -Xcc "-fmodule-map-file=$swift_build_dir/LogseqChatCoreABI.build/module.modulemap" \
  -Xcc "-I$repo_root/Sources/LogseqChatCoreABI/include" \
  -L "$swift_build_dir" \
  -lLogseqChat \
  -framework SwiftUI \
  -framework UIKit \
  -Xlinker -rpath \
  -Xlinker @executable_path/Frameworks \
  "$repo_root/Darwin/Sources/Main.swift" \
  -o "$app_dir/LogseqChat"

plutil -extract Entitlements xml1 -o "$entitlements" "$profile_plist"
plutil -replace application-identifier \
  -string "$expected_app_id" \
  "$entitlements"

codesign --force --sign "$signing_identity" --timestamp=none \
  "$frameworks_dir/libLogseqChat.dylib"
codesign --force --sign "$signing_identity" --timestamp=none \
  --entitlements "$entitlements" \
  "$app_dir"
codesign --verify --deep --strict "$app_dir"

echo "$app_dir"
