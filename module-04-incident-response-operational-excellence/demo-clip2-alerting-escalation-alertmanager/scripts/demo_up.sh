#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

session="mod4-clip2"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1  ->  brew install $1"; exit 1; }; }
log()  { printf "\n[%s] %s\n" "$(date +%H:%M:%S)" "$1"; }
hr()   { printf '%s\n' "------------------------------------------------------------------------"; }

need python3; need tmux; need docker

mkdir -p .run
: > .run/app.log 2>/dev/null
: > .run/model.log 2>/dev/null
: > .run/vector.log 2>/dev/null
: > .run/webhook.log 2>/dev/null

log "Clearing demo ports 5001 8000 8081 8082"
for port in 5001 8000 8081 8082; do
  pids=$(lsof -ti tcp:$port 2>/dev/null || true)
  [ -n "$pids" ] && echo "$pids" | while read -r p; do kill -9 "$p" 2>/dev/null || true; done && echo "  cleared :$port"
done
sleep 0.5

log "Starting Prometheus + Alertmanager + Grafana"
docker compose -f infra/docker-compose.yaml up -d --remove-orphans 2>&1 | tail -5

log "Creating venv and installing deps"
python3 -m venv .venv
BASH_SILENCE_DEPRECATION_WARNING=1 .venv/bin/python -m pip install -q --upgrade pip
BASH_SILENCE_DEPRECATION_WARNING=1 .venv/bin/python -m pip install -q -r requirements.txt

log "Starting model stub on :8081"
nohup .venv/bin/python -m uvicorn app.stubs.model:app \
  --host 0.0.0.0 --port 8081 --log-level warning \
  >> .run/model.log 2>&1 & echo $! > .run/model.pid

for i in $(seq 1 30); do
  curl -sf localhost:8081/mode >/dev/null 2>&1 && echo "[OK] model stub :8081" && break
  sleep 0.5
  if [ "$i" -eq 30 ]; then echo "[ERR] model stub failed"; tail -10 .run/model.log; exit 1; fi
done

log "Starting vector stub on :8082"
nohup .venv/bin/python -m uvicorn app.stubs.vector:app \
  --host 0.0.0.0 --port 8082 --log-level warning \
  >> .run/vector.log 2>&1 & echo $! > .run/vector.pid

for i in $(seq 1 30); do
  curl -sf localhost:8082/mode >/dev/null 2>&1 && echo "[OK] vector stub :8082" && break
  sleep 0.5
  if [ "$i" -eq 30 ]; then echo "[ERR] vector stub failed"; tail -10 .run/vector.log; exit 1; fi
done

log "Starting webhook stub on :5001"
nohup .venv/bin/python -m uvicorn app.stubs.webhook:app \
  --host 0.0.0.0 --port 5001 --log-level warning \
  >> .run/webhook.log 2>&1 & echo $! > .run/webhook.pid

for i in $(seq 1 30); do
  curl -sf localhost:5001/health >/dev/null 2>&1 && echo "[OK] webhook stub :5001" && break
  sleep 0.5
  if [ "$i" -eq 30 ]; then echo "[ERR] webhook stub failed"; tail -10 .run/webhook.log; exit 1; fi
done

log "Starting GenAI alerting service on :8000"
nohup .venv/bin/python -m uvicorn app.main:app \
  --host 0.0.0.0 --port 8000 --log-level warning \
  >> .run/app.log 2>&1 & echo $! > .run/app.pid

for i in $(seq 1 40); do
  curl -sf localhost:8000/health >/dev/null 2>&1 && echo "[OK] app :8000" && break
  sleep 0.5
  if [ "$i" -eq 40 ]; then echo "[ERR] app failed"; tail -20 .run/app.log; exit 1; fi
done

log "Waiting for Prometheus (up to 30s)"
for i in $(seq 1 30); do
  curl -sf localhost:9090/-/ready 2>/dev/null && echo "[OK] Prometheus :9090" && break
  printf "."
  sleep 1
done
echo ""

log "Waiting for Alertmanager (up to 30s)"
for i in $(seq 1 30); do
  curl -sf localhost:9093/-/ready 2>/dev/null && echo "[OK] Alertmanager :9093" && break
  printf "."
  sleep 1
done
echo ""

log "Waiting for Grafana (up to 30s)"
for i in $(seq 1 30); do
  curl -sf localhost:3000/api/health 2>/dev/null | grep -q "ok" && echo "[OK] Grafana :3000" && break
  printf "."
  sleep 1
done
echo ""

# ── tmux session ──────────────────────────────────────────────
t1_title="#[bg=colour27,fg=white,bold]   T1 — ALERT RECEIVER LOGS     #[default]"
t2_title="#[bg=colour46,fg=black,bold]   T2 — DEMO COMMANDS           #[default]"

run_clean() {
  printf "%s" "cd '$ROOT'; clear; env BASH_SILENCE_DEPRECATION_WARNING=1 PS1='$ ' bash --noprofile --norc"
}

log "Building tmux session"
tmux has-session -t "$session" 2>/dev/null && tmux kill-session -t "$session" || true
tmux new-session -d -s "$session" -n "demo" -c "$ROOT" -x 220 -y 50 "$(run_clean)"
tmux split-window -v -p 40 -t "$session":0.0 -c "$ROOT" "$(run_clean)"
tmux set-option -t "$session":0 -w pane-border-status top
tmux set-option -t "$session":0 -w pane-border-format "#{pane_title}"
tmux set-option -t "$session":0 -w pane-border-style "fg=white"
tmux set-option -t "$session":0 -w pane-active-border-style "fg=white"
tmux set-option -t "$session" -g mouse on
tmux set-option -t "$session" -g status off
tmux select-pane -t "$session":0.0 -T "$t1_title"
tmux select-pane -t "$session":0.1 -T "$t2_title"
tmux send-keys -t "$session":0.0 "tail -f .run/webhook.log" Enter
tmux send-keys -t "$session":0.1 "clear" Enter
tmux select-pane -t "$session":0.1

log "All services up"
hr
echo ""
echo "  App           : http://localhost:8000"
echo "  Webhook Stub  : http://localhost:5001"
echo "  Prometheus    : http://localhost:9090"
echo "  Alertmanager  : http://localhost:9093"
echo "  Grafana       : http://localhost:3000  (admin/admin)"
echo ""
echo "  Navigate: Ctrl+b arrow   Detach: Ctrl+b d"
echo ""

if [[ -n "${TMUX:-}" ]]; then
  tmux switch-client -t "$session"
else
  tmux attach-session -t "$session"
fi
