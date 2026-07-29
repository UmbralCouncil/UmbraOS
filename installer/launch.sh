#!/usr/bin/env bash
set -euo pipefail
token="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
socket="/run/umbra-installer/backend.sock"
cleanup() {
  [ -n "${web_pid:-}" ] && kill "$web_pid" 2>/dev/null || true
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
@BUSYBOX@ httpd -f -p 127.0.0.1:43110 -h @WEBROOT@ &
web_pid=$!
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:43110/" >/dev/null; then break; fi
  sleep .1
done
# The native Qt shell owns the window lifetime. When it exits, this script's
# trap tears down both local installer services.
@WEBVIEW@ "http://127.0.0.1:43110/#$token" @ICON@
