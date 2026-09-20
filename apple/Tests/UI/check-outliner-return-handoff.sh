#!/usr/bin/env bash
# Exercise the real editor and key commands in SwiftUI without XCTest.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
device=${1:?Pass the simulator UDID}
build_dir=.build/arm64-apple-ios-simulator/debug
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
xcrun --sdk iphonesimulator swiftc -parse-as-library \
  -target arm64-apple-ios17.0-simulator \
  -I "$build_dir/Modules" -I "$build_dir/LogseqChatCoreABI.build" \
  Sources/LogseqChat/OutlinerEditing.swift \
  Sources/LogseqChat/OutlinerNativeTextMeasurement.swift \
  Sources/LogseqChat/OutlinerInlineEditor.swift \
  Tests/UI/outliner-return-handoff.swift \
  "$build_dir/LogseqChatModel.build/Models.swift.o" -o "$check_dir/check"
xcrun simctl spawn "$device" "$check_dir/check"
