#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
expected_root="$repo_root/_build/apple-toolchains"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/logseq-chat-apple-build-test.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT

assert_contains() {
  local name=$1
  local output=$2
  local expected=$3
  if [[ $output != *"$expected"* ]]; then
    echo "not ok - $name: expected '$expected'" >&2
    echo "$output" >&2
    exit 1
  fi
  echo "ok - $name"
}

for script in build-mobile-ios-simulator.sh build-mobile-ios-device.sh; do
  grep -F 'scripts/build-mobile-ocaml.sh' "$repo_root/scripts/$script" >/dev/null || {
    echo "not ok - $script does not use the shared Dune builder" >&2
    exit 1
  }
  if grep -Eq '\.cmx|output-complete-obj|link-objects.txt|build-mobile-ocaml-deps.sh' \
    "$repo_root/scripts/$script"; then
    echo "not ok - $script contains OCaml dependency or linker internals" >&2
    exit 1
  fi
done
echo "ok - iOS scripts delegate OCaml builds to Dune"

simulator_settings=$(LOGSEQ_CHAT_IOS_PRINT_BUILD_SETTINGS=1 \
  "$repo_root/scripts/build-mobile-ios-simulator.sh")
assert_contains "simulator uses OCaml 5.5" "$simulator_settings" "ocaml-version=5.5.0"
assert_contains "simulator toolchain is workspace-local" "$simulator_settings" \
  "toolchain-root=$expected_root"

device_settings=$(LOGSEQ_CHAT_IOS_PRINT_BUILD_SETTINGS=1 \
  "$repo_root/scripts/build-mobile-ios-device.sh")
assert_contains "device uses OCaml 5.5" "$device_settings" "ocaml-version=5.5.0"
assert_contains "device toolchain is workspace-local" "$device_settings" \
  "toolchain-root=$expected_root"

macos_settings=$(LOGSEQ_CHAT_MACOS_PRINT_BUILD_SETTINGS=1 \
  "$repo_root/scripts/build-macos-app.sh")
assert_contains "macOS toolchain is workspace-local" "$macos_settings" \
  "toolchain-root=$expected_root"

fake_prefix="$temporary_directory/toolchain"
mkdir -p "$fake_prefix/bin"
cat >"$fake_prefix/bin/ocamlopt.opt" <<'SCRIPT'
#!/usr/bin/env bash
case "${1:-}" in
  -version) echo 5.5.0 ;;
  -config) echo architecture: arm64 ;;
  *) exit 2 ;;
esac
SCRIPT
chmod +x "$fake_prefix/bin/ocamlopt.opt"
dependency_stamp="$temporary_directory/dependency-fingerprint"
printf '%s\n' first >"$dependency_stamp"
first_fingerprint=$("$repo_root/scripts/apple-core-fingerprint.sh" \
  "$fake_prefix" arm64-apple-ios17.0 /test-sdk "$dependency_stamp")
repeated_fingerprint=$("$repo_root/scripts/apple-core-fingerprint.sh" \
  "$fake_prefix" arm64-apple-ios17.0 /test-sdk "$dependency_stamp")
if [[ $first_fingerprint != "$repeated_fingerprint" ]]; then
  echo "not ok - unchanged native inputs have a stable fingerprint" >&2
  exit 1
fi
echo "ok - unchanged native inputs have a stable fingerprint"

printf '%s\n' second >"$dependency_stamp"
changed_fingerprint=$("$repo_root/scripts/apple-core-fingerprint.sh" \
  "$fake_prefix" arm64-apple-ios17.0 /test-sdk "$dependency_stamp")
if [[ $first_fingerprint == "$changed_fingerprint" ]]; then
  echo "not ok - dependency changes invalidate the native core cache" >&2
  exit 1
fi
echo "ok - dependency changes invalidate the native core cache"
