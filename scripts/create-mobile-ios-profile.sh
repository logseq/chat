#!/usr/bin/env bash

set -euo pipefail

bundle_id=${LOGSEQ_CHAT_IOS_BUNDLE_ID:-com.logseq.chat}
team_id=${LOGSEQ_CHAT_IOS_TEAM_ID:-}
app_id_prefix=${LOGSEQ_CHAT_IOS_APP_ID_PREFIX:-}
profile_name=${LOGSEQ_CHAT_IOS_PROFILE_NAME:-Logseq Chat Development}
profile_filename=${LOGSEQ_CHAT_IOS_PROFILE_FILENAME:-logseq-chat-development.mobileprovision}
output_path=${LOGSEQ_CHAT_IOS_PROFILE_OUTPUT_PATH:-$HOME/Library/MobileDevice/Provisioning Profiles}
api_key_id=${APP_STORE_CONNECT_API_KEY_ID:-}
api_issuer_id=${APP_STORE_CONNECT_ISSUER_ID:-}
api_key_path=${APP_STORE_CONNECT_API_KEY_PATH:-}
dry_run=${LOGSEQ_CHAT_IOS_DRY_RUN:-0}

die() {
  echo "error: $*" >&2
  exit 1
}

[[ $bundle_id != "com.logseq.logseq" ]] || die "refusing to create a profile for the production Logseq bundle id"
[[ -n $api_key_id ]] || die "set APP_STORE_CONNECT_API_KEY_ID"
[[ -n $api_issuer_id ]] || die "set APP_STORE_CONNECT_ISSUER_ID"
[[ -n $api_key_path ]] || die "set APP_STORE_CONNECT_API_KEY_PATH"
[[ -f $api_key_path ]] || die "App Store Connect API key file was not found: $api_key_path"

if [[ $dry_run == "1" ]]; then
  echo "Would ensure bundle id $bundle_id"
  echo "Would create development profile $profile_name at $output_path/$profile_filename"
  exit 0
fi

mkdir -p "$output_path"
api_json=$(mktemp /tmp/logseq-chat-asc-api.XXXXXX)
profile_path="$output_path/$profile_filename"

python3 - <<'PY' "$api_json" "$api_key_id" "$api_issuer_id" "$api_key_path"
import json
import sys

api_json, key_id, issuer_id, key_path = sys.argv[1:]
with open(key_path, encoding="utf-8") as f:
    key = f.read()

with open(api_json, "w", encoding="utf-8") as f:
    json.dump(
        {
            "key_id": key_id,
            "issuer_id": issuer_id,
            "key": key,
            "duration": 1200,
            "in_house": False,
        },
        f,
    )
PY

set +e
bundle_output=$(
  ruby - <<'RUBY' "$api_key_id" "$api_issuer_id" "$api_key_path" "$app_id_prefix" "$bundle_id"
require "spaceship"
require "spaceship/connect_api/models/bundle_id"

key_id, issuer_id, key_path, app_id_prefix, bundle_id = ARGV

Spaceship::ConnectAPI.auth(
  key_id: key_id,
  issuer_id: issuer_id,
  filepath: key_path,
  duration: 1200,
  in_house: false
)

existing = Spaceship::ConnectAPI::BundleId.find(bundle_id)
if existing
  puts "Bundle id exists: #{existing.identifier}"
else
  if app_id_prefix.nil? || app_id_prefix.empty?
    bundle_ids = Spaceship::ConnectAPI::BundleId.all
    reusable = bundle_ids.find { |item| item.seed_id && item.identifier != "*" }
    reusable ||= bundle_ids.find { |item| item.seed_id }
    raise "Could not infer an App ID prefix; set LOGSEQ_CHAT_IOS_APP_ID_PREFIX" unless reusable
    app_id_prefix = reusable.seed_id
  end

  created = Spaceship::ConnectAPI::BundleId.create(
    name: "LogseqChat",
    platform: "IOS",
    identifier: bundle_id,
    seed_id: app_id_prefix
  )
  puts "Created bundle id: #{created.identifier}"
end
RUBY
)
bundle_status=$?
set -e

if [[ $bundle_status -ne 0 ]]; then
  if [[ $bundle_output == *"A required agreement is missing or has expired"* ]]; then
    die "Apple Developer/App Store Connect agreement is missing or expired; accept it, then rerun this script"
  fi
  echo "$bundle_output" >&2
  exit "$bundle_status"
fi

echo "$bundle_output" >&2

sigh_args=(
  sigh
  --development
  --force
  --include_all_certificates
  --app_identifier "$bundle_id"
  --api_key_path "$api_json"
  --provisioning_name "$profile_name"
  --output_path "$output_path"
  --filename "$profile_filename"
)
if [[ -n $team_id ]]; then
  sigh_args+=(--team_id "$team_id")
fi

set +e
output=$(
  FASTLANE_DISABLE_COLORS=1 FASTLANE_HIDE_CHANGELOG=1 fastlane "${sigh_args[@]}" 2>&1
)
status=$?
set -e

if [[ $status -ne 0 ]]; then
  if [[ $output == *"A required agreement is missing or has expired"* ]]; then
    die "Apple Developer/App Store Connect agreement is missing or expired; accept it, then rerun this script"
  fi
  echo "$output" >&2
  exit "$status"
fi

[[ -f $profile_path ]] || die "fastlane completed but profile was not found: $profile_path"
echo "$profile_path"
