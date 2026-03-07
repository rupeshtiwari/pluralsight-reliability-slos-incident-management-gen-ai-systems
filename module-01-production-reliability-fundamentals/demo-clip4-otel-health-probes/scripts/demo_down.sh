#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INFRA_DIR="$ROOT_DIR/infra"

log() { printf "\n[%s] %s\n" "$(date +%H:%M:%S)" "$1"; }

kill_pid() {
  local pid_file="$1"
  if [[ -f "$pid_file" ]]; then
    local pid
    pid="$(cat "$pid_file" || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" || true
    fi
    rm -f "$pid_file"
  fi
}

log "Stopping app + stubs"
kill_pid "$ROOT_DIR/.run/app.pid"
kill_pid "$ROOT_DIR/.run/model_stub.pid"
kill_pid "$ROOT_DIR/.run/vector_stub.pid"

log "Stopping docker compose stack"
docker compose -f "$INFRA_DIR/docker-compose.yaml" down

log "Done"
