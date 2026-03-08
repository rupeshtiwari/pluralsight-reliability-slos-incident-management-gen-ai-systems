#!/usr/bin/env bash
set -euo pipefail

log(){ printf "\n[%s] %s\n" "$(date +%H:%M:%S)" "$1"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

mkdir -p .run

log "Starting observability stack (Grafana/Prometheus)"
docker compose -f infra/docker-compose.yaml up -d

log "Creating venv (.venv)"
python3 -m venv .venv

log "Installing Python deps"
.venv/bin/python -m pip install -q --upgrade pip
.venv/bin/python -m pip install -q -r requirements.txt

log "Starting model stub on :9001"
nohup .venv/bin/python -m uvicorn stubs.model_stub:app --host 0.0.0.0 --port 9001 > .run/model.log 2>&1 & echo $! > .run/model.pid

log "Starting retrieval stub on :9002"
nohup .venv/bin/python -m uvicorn stubs.retrieval_stub:app --host 0.0.0.0 --port 9002 > .run/retrieval.log 2>&1 & echo $! > .run/retrieval.pid

log "Starting tools stub on :9003"
nohup .venv/bin/python -m uvicorn stubs.tools_stub:app --host 0.0.0.0 --port 9003 > .run/tools.log 2>&1 & echo $! > .run/tools.pid

log "Starting app on :8080"
nohup .venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port 8080 > .run/app.log 2>&1 & echo $! > .run/app.pid

log "Smoke check"
for i in {1..30}; do
  if curl -sf http://localhost:8080/metrics >/dev/null 2>&1; then
    log "Up. Open Grafana: http://localhost:3000 (admin/admin)"
    exit 0
  fi
  sleep 0.5
done

log "App did not become ready. Tail logs:"
tail -n 80 .run/app.log || true
exit 1
