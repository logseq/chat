#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
logseq1_root=${LOGSEQ_1_ROOT:-$(cd "$repo_root/../logseq-1" && pwd)}
db_sync_root="$logseq1_root/deps/db-sync"
base_url=${LOGSEQ_CHAT_LIVE_BASE_URL:-http://127.0.0.1:8787}
username=${LOGSEQ_CHAT_E2E_USERNAME:-e2etest}
password=${LOGSEQ_CHAT_E2E_PASSWORD:-Logseq-e2e}
client_id=${LOGSEQ_CHAT_COGNITO_CLIENT_ID:-69cs1lgme7p8kbgld8n5kseii6}
cognito_endpoint=${LOGSEQ_CHAT_COGNITO_ENDPOINT:-https://cognito-idp.us-east-1.amazonaws.com/}

if [[ ! -d $db_sync_root ]]; then
  echo "error: Logseq-1 db-sync is missing at $db_sync_root" >&2
  exit 1
fi

eval "$(opam env --switch=5.5.0 --set-switch)"

token=${LOGSEQ_CHAT_LIVE_TOKEN:-}
if [[ -z $token ]]; then
  auth_json=$(
    curl -fsS "$cognito_endpoint" \
      -H "X-Amz-Target: AWSCognitoIdentityProviderService.InitiateAuth" \
      -H "Content-Type: application/x-amz-json-1.1" \
      -d "{\"AuthFlow\":\"USER_PASSWORD_AUTH\",\"ClientId\":\"$client_id\",\"AuthParameters\":{\"USERNAME\":\"$username\",\"PASSWORD\":\"$password\"}}"
  )
  token=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["AuthenticationResult"]["AccessToken"])' <<<"$auth_json")
fi

if [[ -z $token ]]; then
  echo "error: could not obtain a Cognito access token" >&2
  exit 1
fi

started_server=0
server_log=""
data_dir=""
if ! curl -fsS "$base_url/health" >/dev/null 2>&1; then
  if [[ ! -f $db_sync_root/worker/dist/node-adapter.js ]]; then
    echo "building Logseq-1 node adapter"
    (cd "$db_sync_root" && pnpm build:node-adapter)
  fi
  data_dir=$(mktemp -d "${TMPDIR:-/tmp}/logseq-live-sync-data.XXXXXX")
  server_log=$(mktemp "${TMPDIR:-/tmp}/logseq-live-sync-server.XXXXXX")
  echo "starting Logseq-1 db-sync on $base_url with data dir $data_dir"
  (
    cd "$db_sync_root"
    DB_SYNC_PORT="${base_url##*:}" \
      DB_SYNC_DATA_DIR="$data_dir" \
      LOGSEQ_CHAT_COGNITO_CLIENT_ID="$client_id" \
      COGNITO_CLIENT_ID="$client_id" \
      ./start.sh
  ) >"$server_log" 2>&1 &
  server_pid=$!
  started_server=1
  cleanup() {
    if [[ $started_server -eq 1 ]]; then
      kill "$server_pid" >/dev/null 2>&1 || true
      wait "$server_pid" >/dev/null 2>&1 || true
    fi
    [[ -n $data_dir ]] && rm -rf "$data_dir"
    [[ -n $server_log ]] && rm -f "$server_log"
  }
  trap cleanup EXIT
  for _ in $(seq 1 40); do
    if curl -fsS "$base_url/health" >/dev/null 2>&1; then
      break
    fi
    if ! kill -0 "$server_pid" >/dev/null 2>&1; then
      echo "error: Logseq-1 db-sync exited before becoming healthy" >&2
      cat "$server_log" >&2 || true
      exit 1
    fi
    sleep 0.5
  done
  if ! curl -fsS "$base_url/health" >/dev/null 2>&1; then
    echo "error: Logseq-1 db-sync did not become healthy on $base_url" >&2
    cat "$server_log" >&2 || true
    exit 1
  fi
fi

dune build --root "$repo_root" shared/native/logseq_chat_live_sync.exe
LOGSEQ_CHAT_LIVE_TOKEN=$token \
  LOGSEQ_CHAT_LIVE_BASE_URL=$base_url \
  dune exec --root "$repo_root" shared/native/logseq_chat_live_sync.exe
