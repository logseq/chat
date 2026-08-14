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
sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
triple="arm64-apple-ios${deployment_target}-simulator"
target_prefix="$ocaml_demo_root/_build/ios-toolchain/$triple-$ocaml_version"
swift_build_dir="$repo_root/.build/arm64-apple-ios-simulator/debug"
core_build_dir="$repo_root/_build/ios-core/simulator"
core_object="$core_build_dir/logseq_chat_runtime.o"
ffi_object="$core_build_dir/logseq_chat_core_ffi.o"
https_object="$core_build_dir/logseq_chat_https_darwin.o"
sqlite_object="$core_build_dir/datascript_sqlite_stubs.o"
app_dir="$repo_root/.build/LogseqChat.app"
frameworks_dir="$app_dir/Frameworks"
xcode_app_dir="$repo_root/.build/Darwin/DerivedData/Build/Products/Debug-iphonesimulator/LogseqChat.app"

if [[ ! -x $target_prefix/bin/ocamlopt.opt ]]; then
  "$ocaml_demo_root/scripts/bootstrap-ios-ocaml.sh" >/dev/null
fi

ocamlopt="$target_prefix/bin/ocamlopt.opt"
ocaml_lib="$target_prefix/lib/ocaml"
clang=$(xcrun --sdk iphonesimulator --find clang)

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
if [[ -f "$xcode_app_dir/Info.plist" ]]; then
  cp "$xcode_app_dir/Info.plist" "$app_dir/Info.plist"
else
  cp "$repo_root/Darwin/Info.plist" "$app_dir/Info.plist"
  "$repo_root/scripts/configure-ios-info-plist.sh" "$app_dir/Info.plist" "com.logseq.chat" "$deployment_target" "iPhoneSimulator"
fi
cp "$swift_build_dir/libLogseqChat.dylib" "$frameworks_dir/libLogseqChat.dylib"

cognito_frameworks=(
  AWSCore.framework
  AWSCognitoIdentityProviderASF.framework
  AWSCognitoIdentityProvider.framework
)
for framework_name in "${cognito_frameworks[@]}"; do
  framework_source="$swift_build_dir/$framework_name"
  [[ -d $framework_source ]] || die "missing Cognito framework: $framework_source"
  cp -R "$framework_source" "$frameworks_dir/"
done

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

xcrun --sdk iphonesimulator swiftc \
  -parse-as-library \
  -module-name LogseqChatShell \
  -target "$triple" \
  -sdk "$sdk_path" \
  -I "$swift_build_dir/Modules" \
  -F "$swift_build_dir" \
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

codesign --force --sign - --timestamp=none "$frameworks_dir/libLogseqChat.dylib"
for framework_name in "${cognito_frameworks[@]}"; do
  framework="$frameworks_dir/$framework_name"
  codesign --force --sign - --timestamp=none "$framework"
done
codesign --force --sign - --timestamp=none "$app_dir"

echo "$app_dir"
