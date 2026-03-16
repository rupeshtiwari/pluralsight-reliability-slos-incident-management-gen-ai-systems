#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

session="mod3-clip2"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1  →  brew install $1"; exit 1; }; }
log()  { printf "\n[%s] %s\n" "$(date +%H:%M:%S)" "$1"; }
hr()   { printf '%s\n' "────────────────────────────────────────────────────────────────────────────"; }

need python3
need tmux
need docker

mkdir -p .run

# ── Kill leftover processes on demo ports ─────────────────────────────────────
log "Clearing demo ports 8000 8081 8082"
for port in 8000 8081 8082; do
  pids=$(lsof -ti tcp:$port 2>/dev/null || true)
  if [ -n "$pids" ]; then
    echo "$pids" | while read -r p; do kill -9 "$p" 2>/dev/null || true; done
    echo "  cleared :$port"
  fi
done
sleep 0.5

# ── Observability stack ───────────────────────────────────────────────────────
log "Starting Prometheus + Grafana"
docker compose -f infra/docker-compose.yaml up -d --remove-orphans 2>&1 | tail -3

# ── Python venv ───────────────────────────────────────────────────────────────
log "Creating venv (.venv)"
python3 -m venv .venv

log "Installing Python deps"
BASH_SILENCE_DEPRECATION_WARNING=1 .venv/bin/python -m pip install -q --upgrade pip
BASH_SILENCE_DEPRECATION_WARNING=1 .venv/bin/python -m pip install -q -r requirements.txt

# ── Start model stub ──────────────────────────────────────────────────────────
log "Starting model stub on :8081"
nohup .venv/bin/python -m uvicorn app.stubs.model:app \
  --host 0.0.0.0 --port 8081 --log-level warning \
  > .run/model.log 2>&1 & echo $! > .run/model.pid

# ── Wait for model stub ───────────────────────────────────────────────────────
for i in $(seq 1 30); do
  curl -sf http://localhost:8081/mode >/dev/null 2>&1 && echo "[OK] model stub :8081" && break
  sleep 0.5
  if [ "$i" -eq 30 ]; then
    echo "[ERR] model stub did not start:"
    tail -n 20 .run/model.log || true
    exit 1
  fi
done

# ── Start vector stub ─────────────────────────────────────────────────────────
log "Starting vector stub on :8082"
nohup .venv/bin/python -m uvicorn app.stubs.vector:app \
  --host 0.0.0.0 --port 8082 --log-level warning \
  > .run/vector.log 2>&1 & echo $! > .run/vector.pid

# ── Wait for vector stub ──────────────────────────────────────────────────────
for i in $(seq 1 30); do
  curl -sf http://localhost:8082/mode >/dev/null 2>&1 && echo "[OK] vector stub :8082" && break
  sleep 0.5
  if [ "$i" -eq 30 ]; then
    echo "[ERR] vector stub did not start:"
    tail -n 20 .run/vector.log || true
    exit 1
  fi
done

# ── Start app ─────────────────────────────────────────────────────────────────
log "Starting GenAI service on :8000"
nohup .venv/bin/python -m uvicorn app.main:app \
  --host 0.0.0.0 --port 8000 --log-level warning \
  > .run/app.log 2>&1 & echo $! > .run/app.pid

# ── Wait for app ──────────────────────────────────────────────────────────────
for i in $(seq 1 40); do
  curl -sf http://localhost:8000/health >/dev/null 2>&1 && echo "[OK] app :8000" && break
  sleep 0.5
  if [ "$i" -eq 40 ]; then
    echo "[ERR] app did not start:"
    tail -n 40 .run/app.log || true
    exit 1
  fi
done

# ── Wait for Grafana (takes 15-20s to boot) ───────────────────────────────────
log "Waiting for Grafana to be ready (up to 30s)"
for i in $(seq 1 30); do
  if curl -sf http://localhost:3000/api/health 2>/dev/null | grep -q "ok"; then
    echo "[OK] Grafana :3000"
    break
  fi
  printf "."
  sleep 1
  if [ "$i" -eq 30 ]; then
    echo ""
    echo "[WARN] Grafana not ready yet — continue anyway, it may still be booting"
  fi
done
echo ""

# ── All up summary ────────────────────────────────────────────────────────────
log "All services up"
hr
echo ""
echo "  App         : http://localhost:8000"
echo "  Model stub  : http://localhost:8081"
echo "  Vector stub : http://localhost:8082"
echo "  Prometheus  : http://localhost:9090"
echo "  Grafana     : http://localhost:3000  (admin/admin)"
echo ""

# ── Hard-coded coloured pane titles ──────────────────────────────────────────
t1_title="#[bg=colour27,fg=white,bold]   T1 — APP LOGS               #[default]"
t2_title="#[bg=colour46,fg=black,bold]   T2 — DEMO COMMANDS          #[default]"

run_clean() {
  printf "%s" "cd '$ROOT'; clear; env BASH_SILENCE_DEPRECATION_WARNING=1 PS1='$ ' bash --noprofile --norc"
}

log "Building tmux session"

tmux has-session -t "$session" 2>/dev/null && tmux kill-session -t "$session" || true

# Two panes:
#   ┌─────────────────────────────────────────────┐
#   │  T1 — APP LOGS            (blue, top 60%)   │
#   ├─────────────────────────────────────────────┤
#   │  T2 — DEMO COMMANDS       (green, btm 40%)  │
#   └─────────────────────────────────────────────┘
tmux new-session -d -s "$session" -n "demo" -c "$ROOT" -x 220 -y 50 "$(run_clean)"
tmux split-window -v -p 40 -t "$session":0.0 -c "$ROOT" "$(run_clean)"

tmux set-option -t "$session":0 -w pane-border-status top
tmux set-option -t "$session":0 -w pane-border-format "#{pane_title}"
tmux set-option -t "$session":0 -w pane-border-style        "fg=white"
tmux set-option -t "$session":0 -w pane-active-border-style "fg=white"
tmux set-option -t "$session" -g mouse on

tmux select-pane -t "$session":0.0 -T "$t1_title"
tmux select-pane -t "$session":0.1 -T "$t2_title"

tmux send-keys -t "$session":0.0 "tail -f .run/app.log" Enter
tmux send-keys -t "$session":0.1 "clear" Enter

tmux select-pane -t "$session":0.1

log "Attaching to session '$session'"
hr
echo ""
echo "  ┌─────────────────────────────────────────────┐"
echo "  │  T1 — APP LOGS            (blue, top)       │"
echo "  ├─────────────────────────────────────────────┤"
echo "  │  T2 — DEMO COMMANDS       (green, bottom)   │"
echo "  └─────────────────────────────────────────────┘"
echo ""
echo "  Navigate : Ctrl+b arrow   Detach: Ctrl+b d"
echo ""

if [[ -n "${TMUX:-}" ]]; then
  tmux switch-client -t "$session"
else
  tmux attach-session -t "$session"
fi
