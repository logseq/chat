#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ocaml_demo_root=${LOGSEQ_CHAT_OCAML_DEMO_ROOT:-/Users/tiensonqin/Codes/projects/ocaml-demo}
ocaml_version=${LOGSEQ_CHAT_MACOS_OCAML_VERSION:-5.5.0}
deployment_target=${LOGSEQ_CHAT_MACOS_DEPLOYMENT_TARGET:-14.0}
configuration=${LOGSEQ_CHAT_MACOS_CONFIGURATION:-release}
bundle_id=${LOGSEQ_CHAT_MACOS_BUNDLE_ID:-com.logseq.chat}
toolchain_name="host-$ocaml_version-macos$deployment_target"
target_prefix="$ocaml_demo_root/_build/macos-toolchain/$toolchain_name"
triple="arm64-apple-macosx$deployment_target"
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
core_build_dir="$repo_root/_build/macos-core"
core_object="$core_build_dir/logseq_chat_runtime.o"
ffi_object="$core_build_dir/logseq_chat_core_ffi.o"
https_object="$core_build_dir/logseq_chat_https_darwin.o"
sqlite_object="$core_build_dir/datascript_sqlite_stubs.o"
app_dir="$repo_root/.build/macos/LogseqChat.app"
contents_dir="$app_dir/Contents"
frameworks_dir="$contents_dir/Frameworks"
resources_dir="$contents_dir/Resources"

die() {
  echo "error: $*" >&2
  exit 1
}

case "$configuration" in
  debug)
    swift_shell_flags=(-Onone -g)
    ;;
  release)
    swift_shell_flags=(-O)
    ;;
  *)
    die "unsupported macOS build configuration: $configuration"
    ;;
esac

if [[ ${LOGSEQ_CHAT_MACOS_PRINT_BUILD_SETTINGS:-0} == 1 ]]; then
  echo "configuration=$configuration ocaml-version=$ocaml_version target=$triple toolchain=$toolchain_name"
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

xcrun --sdk macosx swiftc \
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
  -framework AppKit \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  "$repo_root/Darwin/Sources/Main.swift" \
  -o "$contents_dir/MacOS/LogseqChat"

codesign --force --sign - --timestamp=none "$frameworks_dir/libLogseqChat.dylib"
codesign --force --sign - --timestamp=none "$app_dir"
codesign --verify --deep --strict "$app_dir"

echo "$app_dir"
