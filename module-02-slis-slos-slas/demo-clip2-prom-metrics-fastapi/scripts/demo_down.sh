#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

kill_if(){ if [ -f "$1" ]; then kill "$(cat "$1")" >/dev/null 2>&1 || true; fi }

kill_if .run/app.pid
kill_if .run/model.pid
kill_if .run/retrieval.pid
kill_if .run/tools.pid

docker compose -f infra/docker-compose.yaml down >/dev/null 2>&1 || true

echo "[down] done"
