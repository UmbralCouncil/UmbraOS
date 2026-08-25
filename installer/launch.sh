#!/usr/bin/env bash
set -euo pipefail
token="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
socket="/run/umbra-installer/backend.sock"
cleanup() {
  [ -n "${backend_pid:-}" ] && sudo @BACKEND@ stop 2>/dev/null || true
}
trap cleanup EXIT INT TERM
sudo @BACKEND@ serve "$socket" "$token" &
backend_pid=$!
for _ in $(seq 1 50); do
  if [ -S "$socket" ]; then break; fi
  sleep .1
done
[ -S "$socket" ] || { echo "privileged installer backend did not start" >&2; exit 1; }
# The native egui process owns the window lifetime. When it exits, this
# script's trap tears down the privileged backend.
@GUI@ "$token"
