#!/usr/bin/env bash
set -euo pipefail
token="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
cleanup() {
  [ -n "${server_pid:-}" ] && sudo kill "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
sudo env UMBRA_INSTALLER_TOKEN="$token" @BACKEND@ serve "$token" &
server_pid=$!
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:43110/" >/dev/null; then break; fi
  sleep .1
done
@FIREFOX@ --new-window --kiosk "http://127.0.0.1:43110/#$token"
