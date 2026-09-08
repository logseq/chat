#!/usr/bin/env bash

set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

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
https_object="$core_build_dir/logseq_chat_https_darwin.o"
crypto_object="$core_build_dir/logseq_chat_crypto_darwin.o"
app_dir="$repo_root/.build/macos/LogseqChat.app"
contents_dir="$app_dir/Contents"
frameworks_dir="$contents_dir/Frameworks"
resources_dir="$contents_dir/Resources"

[[ $configuration == debug || $configuration == release ]] \
  || die "unsupported macOS build configuration: $configuration"

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
ocaml_lib="$target_prefix/lib/ocaml"
clang=$(xcrun --sdk macosx --find clang)
mkdir -p "$core_build_dir"

core_object=$(LOGSEQ_CHAT_SQLITE_LIB_DIR="$sdk_path/usr/lib" \
  LOGSEQ_CHAT_SQLITE_LINK_FILE="$sdk_path/usr/lib/libsqlite3.tbd" \
  "$repo_root/scripts/build-mobile-ocaml.sh" "$target_prefix" macos_arm64)

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

cd "$repo_root"
swift build \
  -c "$configuration" \
  --disable-keychain \
  --triple "$triple" \
  --sdk "$sdk_path" \
  -Xswiftc -DLOGSEQ_CHAT_CORE \
  -Xlinker "$core_object" \
  -Xlinker "$https_object" \
  -Xlinker "$crypto_object" \
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

for bundle in "$swift_build_dir"/*.bundle; do
  [[ -d $bundle ]] || continue
  cp -R "$bundle" "$resources_dir/"
done

resource_bundle="$resources_dir/logseq-chat_LogseqChat.bundle"
[[ -d $resource_bundle ]] || die "LogseqChat resource bundle was not produced by SwiftPM"
bundle_resources="$resource_bundle/Contents/Resources"
mkdir -p "$bundle_resources"
while IFS= read -r resource; do
  mv "$resource" "$bundle_resources/"
done < <(find "$resource_bundle" -mindepth 1 -maxdepth 1 \
  ! -name Contents ! -name Info.plist -print)
mv "$resource_bundle/Info.plist" "$resource_bundle/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string "logseq-chat.LogseqChat.resources" \
  "$resource_bundle/Contents/Info.plist"
plutil -insert CFBundleInfoDictionaryVersion -string "6.0" \
  "$resource_bundle/Contents/Info.plist"
plutil -insert CFBundleName -string "logseq-chat_LogseqChat" \
  "$resource_bundle/Contents/Info.plist"
plutil -insert CFBundlePackageType -string BNDL \
  "$resource_bundle/Contents/Info.plist"
xcrun actool \
  --compile "$bundle_resources" \
  --platform macosx \
  --minimum-deployment-target "$deployment_target" \
  --target-device mac \
  --output-partial-info-plist "$core_build_dir/macos-assets.plist" \
  "$repo_root/Sources/LogseqChat/Resources/Icons.xcassets" \
  >/dev/null
[[ -f $bundle_resources/Assets.car ]] || die "failed to compile the macOS icon asset catalog"

cp "$swift_build_dir/LogseqChatShell" "$contents_dir/MacOS/LogseqChat"
codesign --force --sign - --timestamp=none "$app_dir"
codesign --verify --deep --strict "$app_dir"

echo "$app_dir"
