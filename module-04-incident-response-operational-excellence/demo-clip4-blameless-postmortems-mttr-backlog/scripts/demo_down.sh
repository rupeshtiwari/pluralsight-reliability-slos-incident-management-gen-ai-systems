#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

tmux kill-session -t "mod4-clip4" 2>/dev/null || true

kill_if() { [ -f "$1" ] && kill "$(cat "$1")" 2>/dev/null || true; }
kill_if .run/exporter.pid

for port in 8090; do
  pids=$(lsof -ti tcp:$port 2>/dev/null || true)
  [ -n "$pids" ] && echo "$pids" | while read -r p; do kill -9 "$p" 2>/dev/null || true; done && echo "[down] killed :$port"
done

docker compose -f infra/docker-compose.yaml down --remove-orphans 2>/dev/null || true

# Restore staged postmortem so repo stays clean
if [ -f staging/INC-2024-003.yaml ]; then
  mv staging/INC-2024-003.yaml postmortems/INC-2024-003.yaml
  echo "[down] restored INC-2024-003.yaml to postmortems/"
fi
rmdir staging 2>/dev/null || true

rm -f .run/*.pid
find "$ROOT" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true

echo "[down] done"
echo ""
echo "  If Docker Desktop is frozen:"
echo "  killall Docker\\ Desktop 2>/dev/null; killall com.docker.backend 2>/dev/null"
