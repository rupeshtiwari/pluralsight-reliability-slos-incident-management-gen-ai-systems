#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

tmux kill-session -t "mod4-clip2" 2>/dev/null || true

kill_if() { [ -f "$1" ] && kill "$(cat "$1")" 2>/dev/null || true; }
kill_if .run/app.pid
kill_if .run/model.pid
kill_if .run/vector.pid
kill_if .run/webhook.pid

for port in 5001 8000 8081 8082; do
  pids=$(lsof -ti tcp:$port 2>/dev/null || true)
  [ -n "$pids" ] && echo "$pids" | while read -r p; do kill -9 "$p" 2>/dev/null || true; done && echo "[down] killed :$port"
done

docker compose -f infra/docker-compose.yaml down --remove-orphans 2>/dev/null || true

rm -f .run/*.pid
echo "[down] done"
echo ""
echo "  If Docker Desktop is frozen:"
echo "  killall Docker\\ Desktop 2>/dev/null; killall com.docker.backend 2>/dev/null"
