#!/usr/bin/env bash
# Exercise the real inline asset preview layout without XCTest.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
device=${1:?Pass the simulator UDID}
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
xcrun --sdk iphonesimulator swiftc -parse-as-library \
  -target arm64-apple-ios17.0-simulator \
  Sources/LogseqChat/LGChatInlineImage.swift \
  Tests/UI/inline-image-layout.swift -o "$check_dir/check"
xcrun simctl spawn "$device" "$check_dir/check"
