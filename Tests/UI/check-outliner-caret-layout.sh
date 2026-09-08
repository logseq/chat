#!/usr/bin/env bash
# Check compact editor caret geometry against a full-height UITextView.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
device=${1:?Pass the simulator UDID}
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
xcrun --sdk iphonesimulator swiftc -parse-as-library \
  -target arm64-apple-ios17.0-simulator \
  Sources/LogseqChat/OutlinerNativeTextMeasurement.swift \
  Tests/UI/outliner-caret-layout.swift -o "$check_dir/check"
xcrun simctl spawn "$device" "$check_dir/check"
