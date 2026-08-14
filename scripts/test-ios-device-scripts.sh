#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

failures=0

if grep -Eq 'opam exec --switch=(simulator|ios|android)-|5\.4\.1' \
  "$repo_root/scripts/build-mobile-ocaml-deps.sh"; then
  echo "not ok - mobile dependency build references a legacy cross switch" >&2
  failures=$((failures + 1))
fi

for module in \
  logseq_chat_edn \
  logseq_chat_entity_sync \
  logseq_chat_graph_mutation \
  logseq_chat_graph_read \
  logseq_chat_graph_store \
  logseq_chat_logseq_storage_codec \
  logseq_chat_snapshot \
  logseq_chat_sse \
  logseq_chat_sync_checkpoint \
  logseq_chat_sync_protocol \
  logseq_chat_sync_session \
  logseq_chat_sync_state; do
  if ! grep -q "core/$module.ml" "$repo_root/scripts/build-mobile-ios-device.sh"; then
    echo "not ok - device build omits OCaml module: $module" >&2
    failures=$((failures + 1))
  fi
done

for framework in \
  AWSCore.framework \
  AWSCognitoIdentityProviderASF.framework \
  AWSCognitoIdentityProvider.framework; do
  if grep -q "$framework" "$repo_root/scripts/build-mobile-ios-device.sh"; then
    echo "not ok - device build embeds legacy Cognito framework: $framework" >&2
    failures=$((failures + 1))
  fi
done

if ! grep -q 'LOGSEQ_CHAT_IOS_KEYCHAIN' \
  "$repo_root/scripts/build-mobile-ios-device.sh"; then
  echo "not ok - device build cannot select an isolated signing keychain" >&2
  failures=$((failures + 1))
fi

if ! grep -q 'restore_keychain_search_list' \
  "$repo_root/scripts/build-mobile-ios-device.sh"; then
  echo "not ok - device build does not restore the signing keychain search list" >&2
  failures=$((failures + 1))
fi

if ! grep -q 'security list-keychains -d user -s' \
  "$repo_root/scripts/build-mobile-ios-device.sh"; then
  echo "not ok - device build does not add its signing keychain to the search list" >&2
  failures=$((failures + 1))
fi

if ! grep -q 'NSAllowsLocalNetworking' \
  "$repo_root/scripts/configure-ios-info-plist.sh"; then
  echo "not ok - iOS app does not allow an explicitly configured local API" >&2
  failures=$((failures + 1))
fi

if ! grep -q 'NSLocalNetworkUsageDescription' \
  "$repo_root/scripts/configure-ios-info-plist.sh"; then
  echo "not ok - iOS app does not explain local network access" >&2
  failures=$((failures + 1))
fi

if ! grep -q 'rm -f "$swift_build_dir/LogseqChatShell"' \
  "$repo_root/scripts/build-mobile-ios-device.sh"; then
  echo "not ok - device build does not relink after native core changes" >&2
  failures=$((failures + 1))
fi

check_rejects() {
  local name=$1
  local expected=$2
  shift 2

  set +e
  local output
  output=$("$@" 2>&1)
  local status=$?
  set -e

  if [[ $status -eq 0 ]]; then
    echo "not ok - $name: command succeeded" >&2
    failures=$((failures + 1))
    return
  fi

  if [[ $output != *"$expected"* ]]; then
    echo "not ok - $name: expected '$expected'" >&2
    echo "$output" >&2
    failures=$((failures + 1))
    return
  fi

  echo "ok - $name"
}

check_succeeds() {
  local name=$1
  local expected=$2
  shift 2

  set +e
  local output
  output=$("$@" 2>&1)
  local status=$?
  set -e

  if [[ $status -ne 0 ]]; then
    echo "not ok - $name: command failed" >&2
    echo "$output" >&2
    failures=$((failures + 1))
    return
  fi

  if [[ $output != *"$expected"* ]]; then
    echo "not ok - $name: expected '$expected'" >&2
    echo "$output" >&2
    failures=$((failures + 1))
    return
  fi

  echo "ok - $name"
}

check_rejects \
  "device build refuses production Logseq bundle id" \
  "refusing to build the production Logseq bundle id" \
  env LOGSEQ_CHAT_IOS_BUNDLE_ID=com.logseq.logseq \
    "$repo_root/scripts/build-mobile-ios-device.sh"

check_rejects \
  "device install refuses production Logseq bundle id" \
  "refusing to install over the production Logseq bundle id" \
  env LOGSEQ_CHAT_IOS_BUNDLE_ID=com.logseq.logseq \
    "$repo_root/scripts/install-mobile-ios-device.sh"

check_rejects \
  "device build requires a provisioning profile" \
  "set LOGSEQ_CHAT_IOS_PROFILE to a development provisioning profile for com.logseq.chat" \
  env -u LOGSEQ_CHAT_IOS_PROFILE \
    "$repo_root/scripts/build-mobile-ios-device.sh"

check_succeeds \
  "device build selects release configuration" \
  "configuration=release swift-build-dir=$repo_root/.build/arm64-apple-ios/release" \
  env LOGSEQ_CHAT_IOS_BUILD_CONFIGURATION=release \
    LOGSEQ_CHAT_IOS_PRINT_BUILD_SETTINGS=1 \
    "$repo_root/scripts/build-mobile-ios-device.sh"

check_succeeds \
  "device build keeps debug configuration available" \
  "configuration=debug swift-build-dir=$repo_root/.build/arm64-apple-ios/debug" \
  env LOGSEQ_CHAT_IOS_BUILD_CONFIGURATION=debug \
    LOGSEQ_CHAT_IOS_PRINT_BUILD_SETTINGS=1 \
    "$repo_root/scripts/build-mobile-ios-device.sh"

check_rejects \
  "device build rejects unsupported configuration" \
  "unsupported iOS build configuration: profile" \
  env LOGSEQ_CHAT_IOS_BUILD_CONFIGURATION=profile \
    LOGSEQ_CHAT_IOS_PRINT_BUILD_SETTINGS=1 \
    "$repo_root/scripts/build-mobile-ios-device.sh"

check_rejects \
  "device install requires a provisioning profile" \
  "set LOGSEQ_CHAT_IOS_PROFILE to a development provisioning profile for com.logseq.chat" \
  env -u LOGSEQ_CHAT_IOS_PROFILE \
    "$repo_root/scripts/install-mobile-ios-device.sh"

fake_profile=$(mktemp /tmp/logseq-chat-fake-mobileprovision.XXXXXX)
fake_bin=$(mktemp -d /tmp/logseq-chat-fake-bin.XXXXXX)
cat >"$fake_bin/xcrun" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == "devicectl list devices" ]]; then
  cat <<'DEVICES'
Name        Hostname                           Identifier                             State                Model
---------   --------------------------------   ------------------------------------   ------------------   ---------------------------
iPhone      iPhone.coredevice.local            ACC1F5DA-71E4-560F-9818-FC6B1517D6A0   unavailable          iPhone 15 (iPhone15,4)
DEVICES
  exit 0
fi

echo "unexpected xcrun invocation: $*" >&2
exit 42
SH
chmod +x "$fake_bin/xcrun"

check_rejects \
  "device install reports unavailable target before build" \
  "target iOS device 'iPhone' is unavailable" \
  env PATH="$fake_bin:$PATH" \
    LOGSEQ_CHAT_IOS_PROFILE="$fake_profile" \
    LOGSEQ_CHAT_IOS_DEVICE=iPhone \
    "$repo_root/scripts/install-mobile-ios-device.sh"

check_rejects \
  "profile creation refuses production Logseq bundle id" \
  "refusing to create a profile for the production Logseq bundle id" \
  env LOGSEQ_CHAT_IOS_BUNDLE_ID=com.logseq.logseq \
    "$repo_root/scripts/create-mobile-ios-profile.sh"

check_rejects \
  "profile creation requires API key id" \
  "set APP_STORE_CONNECT_API_KEY_ID" \
  env -u APP_STORE_CONNECT_API_KEY_ID \
    "$repo_root/scripts/create-mobile-ios-profile.sh"

check_rejects \
  "profile creation requires API issuer id" \
  "set APP_STORE_CONNECT_ISSUER_ID" \
  env -u APP_STORE_CONNECT_ISSUER_ID \
    "$repo_root/scripts/create-mobile-ios-profile.sh"

check_rejects \
  "profile creation requires API private key file" \
  "App Store Connect API key file was not found" \
  env APP_STORE_CONNECT_API_KEY_PATH=/tmp/logseq-chat-missing-auth-key.p8 \
    "$repo_root/scripts/create-mobile-ios-profile.sh"

fake_key=$(mktemp /tmp/logseq-chat-fake-auth-key.XXXXXX)
cat >"$fake_key" <<'KEY'
-----BEGIN PRIVATE KEY-----
fake
-----END PRIVATE KEY-----
KEY

check_succeeds \
  "profile creation dry run ensures bundle id before profile" \
  "Would ensure bundle id com.logseq.chat" \
  env LOGSEQ_CHAT_IOS_DRY_RUN=1 \
    APP_STORE_CONNECT_API_KEY_ID=fake-key-id \
    APP_STORE_CONNECT_ISSUER_ID=fake-issuer-id \
    APP_STORE_CONNECT_API_KEY_PATH="$fake_key" \
    "$repo_root/scripts/create-mobile-ios-profile.sh"

if [[ $failures -ne 0 ]]; then
  exit 1
fi
