#!/usr/bin/env bash
# Run the focused backend check without XCTest or swift test.
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"
swift build --target LUIAppleBackend --disable-sandbox
build_dir=$(swift build --show-bin-path --disable-sandbox)
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -I "$build_dir/Modules" \
  Tests/UI/drawer-extension-interaction.swift \
  "$build_dir"/LUIAppleBackend.build/*.o \
  -o "$check_dir/check"
"$check_dir/check"
