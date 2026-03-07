#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/app"
INFRA_DIR="$ROOT_DIR/infra"

log() { printf "\n[%s] %s\n" "$(date +%H:%M:%S)" "$1"; }

# Guardrails
if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found. Run ../../setup_all.sh and ensure Docker Desktop is installed." >&2
  exit 1
fi

# Ensure docker is up
if ! docker info >/dev/null 2>&1; then
  echo "Docker is not running. Start Docker Desktop and retry." >&2
  exit 1
fi

log "Starting observability stack (Grafana/Prometheus/Tempo/Collector)"
docker compose -f "$INFRA_DIR/docker-compose.yaml" up -d

# Python venv
PY=python3
if command -v python3.11 >/dev/null 2>&1; then
  PY=python3.11
fi

log "Creating venv (.venv)"
cd "$ROOT_DIR"
$PY -m venv .venv

log "Installing Python deps"
. .venv/bin/activate
pip install --upgrade pip >/dev/null
pip install -r "$APP_DIR/requirements.txt" >/dev/null

mkdir -p "$ROOT_DIR/.run"

log "Starting model stub on :9001"
nohup .venv/bin/uvicorn model_stub:app --host 127.0.0.1 --port 9001 --app-dir "$APP_DIR" \
  > "$ROOT_DIR/.run/model_stub.log" 2>&1 &
echo $! > "$ROOT_DIR/.run/model_stub.pid"

log "Starting vector stub on :9002"
nohup .venv/bin/uvicorn vector_stub:app --host 127.0.0.1 --port 9002 --app-dir "$APP_DIR" \
  > "$ROOT_DIR/.run/vector_stub.log" 2>&1 &
echo $! > "$ROOT_DIR/.run/vector_stub.pid"

log "Starting app on :8080"
nohup .venv/bin/uvicorn main:app --host 0.0.0.0 --port 8080 --app-dir "$APP_DIR" \
  > "$ROOT_DIR/.run/app.log" 2>&1 &
echo $! > "$ROOT_DIR/.run/app.pid"

log "Smoke check"
for i in {1..30}; do
  if curl -sf http://localhost:8080/live >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
  if [[ $i -eq 30 ]]; then
    echo "App did not become ready. Check .run/app.log" >&2
    exit 1
  fi
done

log "Up. Open Grafana: http://localhost:3000"
log "Run story: ./scripts/demo_run_story.sh"
