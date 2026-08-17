#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

# Authentication is an isolated platform effect. Disabling its trait keeps the
# reusable state tests independent from the Amplify source build.
swift test --disable-default-traits --enable-code-coverage --skip XCSkipTests

bin_path=$(swift build --disable-default-traits --show-bin-path)
test_binary="$bin_path/logseq-chatPackageTests.xctest/Contents/MacOS/logseq-chatPackageTests"
profile="$bin_path/codecov/default.profdata"
coverage_sources=(
  Sources/LogseqChatModel/Models.swift
  Sources/LogseqChatModel/GraphLocalStorage.swift
  Sources/LogseqChatModel/CoreExecutor.swift
  Sources/LogseqChat/GraphSyncCoordinator.swift
  Sources/LogseqChat/OutlinerEditing.swift
  Sources/LogseqChat/MobileChromePolicy.swift
  Sources/LogseqChat/SidebarDragPolicy.swift
  Sources/LogseqChat/SidebarNavigation.swift
)

coverage_report=$(
  xcrun llvm-cov report "$test_binary" \
    -instr-profile="$profile" \
    "${coverage_sources[@]}"
)
printf '%s\n' "$coverage_report"

if ! awk '
  $1 == "TOTAL" {
    found = 1
    if ($4 != "100.00%" || $7 != "100.00%" || $10 != "100.00%") {
      exit 1
    }
  }
  END { if (!found) exit 1 }
' <<<"$coverage_report"; then
  echo "error: reusable Swift logic must have 100% region, function, and line coverage" >&2
  exit 1
fi
