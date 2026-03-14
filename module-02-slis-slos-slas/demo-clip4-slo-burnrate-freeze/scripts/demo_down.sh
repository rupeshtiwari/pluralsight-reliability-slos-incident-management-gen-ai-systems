#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Kill by saved PID files first (clean path)
kill_if(){ if [ -f "$1" ]; then kill "$(cat "$1")" >/dev/null 2>&1 || true; fi }
kill_if .run/app.pid
kill_if .run/model.pid
kill_if .run/retrieval.pid
kill_if .run/tools.pid

# Force-clear every demo port — kills anything still holding the socket
# NOTE: xargs -r is GNU-only and does nothing on macOS; use a while-read loop instead
for port in 8080 9001 9002 9003; do
  PIDS=$(lsof -ti tcp:$port 2>/dev/null || true)
  if [ -n "$PIDS" ]; then
    echo "$PIDS" | while read -r p; do kill -9 "$p" 2>/dev/null || true; done
    echo "[down] killed :$port"
  fi
done

docker compose -f infra/docker-compose.yaml down --remove-orphans >/dev/null 2>&1 || true
echo "[down] done"
