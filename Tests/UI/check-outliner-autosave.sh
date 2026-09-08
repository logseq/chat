#!/usr/bin/env bash
# Exercise the real Swift effect scheduler without XCTest.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
swift build --product LogseqChat --disable-sandbox -Xswiftc -enable-testing
build_dir=$(swift build --show-bin-path --disable-sandbox)
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -I "$build_dir/Modules" \
  -I "$build_dir/LogseqChatCoreABI.build" Tests/UI/outliner-autosave.swift \
  "$build_dir/libLogseqChat.a" -o "$check_dir/check"
"$check_dir/check"
