#!/usr/bin/env bash
set -euo pipefail

PATH="@PATH@"
SOCKET="@SOCKET@"

fail() {
  printf 'Status: 503 Service Unavailable\r\n'
  printf 'Content-Type: text/plain\r\n'
  printf 'Cache-Control: no-store\r\n\r\n'
  printf 'Umbra Installer privileged backend is unavailable.\n'
  exit 0
}

body="$(head -c "${CONTENT_LENGTH:-0}")"
[ -n "$body" ] || body='{}'
request="$(
  jq -cn \
    --arg token "${HTTP_X_UMBRA_TOKEN:-}" \
    --arg action "${QUERY_STRING#action=}" \
    --arg method "${REQUEST_METHOD:-GET}" \
    --argjson body "$body" \
    '{token:$token,action:$action,method:$method,body:$body}'
)" || fail

printf '%s' "$request" |
  socat - "UNIX-CONNECT:$SOCKET" || fail
