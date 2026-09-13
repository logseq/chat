#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
module=$1
sdk=$2
triple=$3
deployment_target=$4
output=$5
shift 5
work=$(mktemp -d /tmp/logseq-app-intents.XXXXXX)
trap 'rm -rf "$work"' EXIT
sources=()
compiler_options=()
for arg in "$@"; do
  if [[ $arg == *.swift ]]; then sources+=("$arg"); else compiler_options+=("$arg"); fi
done
printf '%s\n' "${sources[@]}" > "$work/sources"
printf '%s\n' "$work/values.swiftconstvalues" > "$work/values"
xcrun swiftc -frontend -typecheck -parse-as-library -sdk "$sdk" -target "$triple" \
  -module-name "$module" -const-gather-protocols-file "$repo_root/scripts/app-intents-protocols.json" \
  -emit-const-values-path "$work/values.swiftconstvalues" "${compiler_options[@]}" "${sources[@]}"
xcrun appintentsmetadataprocessor --output "$output" \
  --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
  --module-name "$module" --sdk-root "$sdk" \
  --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
  --platform-family iOS --deployment-target "$deployment_target" --target-triple "$triple" \
  --source-file-list "$work/sources" --swift-const-vals-list "$work/values"
[[ -s "$output/Metadata.appintents/extract.actionsdata" ]]
