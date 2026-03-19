#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

session="mod4-clip4"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1  ->  brew install $1"; exit 1; }; }
log()  { printf "\n[%s] %s\n" "$(date +%H:%M:%S)" "$1"; }
hr()   { printf '%s\n' "------------------------------------------------------------------------"; }

need python3; need tmux; need docker

mkdir -p .run
: > .run/exporter.log 2>/dev/null

# ── Clear stale bytecode ─────────────────────────────────────
find "$ROOT" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true

log "Clearing demo port 8090"
for port in 8090; do
  pids=$(lsof -ti tcp:$port 2>/dev/null || true)
  [ -n "$pids" ] && echo "$pids" | while read -r p; do kill -9 "$p" 2>/dev/null || true; done && echo "  cleared :$port"
done
sleep 0.5

# ── Stage INC-2024-003 for live addition during demo ─────────
log "Staging INC-2024-003 for live demo"
mkdir -p staging
if [ -f postmortems/INC-2024-003.yaml ]; then
  mv postmortems/INC-2024-003.yaml staging/INC-2024-003.yaml
  echo "  Moved INC-2024-003.yaml to staging/"
elif [ -f staging/INC-2024-003.yaml ]; then
  echo "  Already staged"
else
  echo "  ERROR: INC-2024-003.yaml not found in postmortems/ or staging/"
  exit 1
fi

log "Starting Prometheus + Grafana"
docker compose -f infra/docker-compose.yaml up -d --remove-orphans 2>&1 | tail -5

log "Creating venv and installing deps"
python3 -m venv .venv
BASH_SILENCE_DEPRECATION_WARNING=1 .venv/bin/python -m pip install -q --upgrade pip
BASH_SILENCE_DEPRECATION_WARNING=1 .venv/bin/python -m pip install -q -r requirements.txt

log "Starting incident metrics exporter on :8090 (2 postmortems)"
POSTMORTEM_DIR="$ROOT/postmortems" \
nohup .venv/bin/python -m uvicorn app.exporter:app \
  --host 0.0.0.0 --port 8090 --log-level warning \
  >> .run/exporter.log 2>&1 & echo $! > .run/exporter.pid

for i in $(seq 1 30); do
  curl -sf localhost:8090/health >/dev/null 2>&1 && echo "[OK] exporter :8090" && break
  sleep 0.5
  if [ "$i" -eq 30 ]; then echo "[ERR] exporter failed"; tail -10 .run/exporter.log; exit 1; fi
done

log "Waiting for Prometheus (up to 30s)"
for i in $(seq 1 30); do
  curl -sf localhost:9090/-/ready 2>/dev/null && echo "[OK] Prometheus :9090" && break
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

# Wait for first successful scrape so baseline dashboard has data
log "Waiting for baseline metrics in Prometheus (up to 30s)"
for i in $(seq 1 30); do
  curl -sf -G localhost:9090/api/v1/query --data-urlencode 'query=incident_total' 2>/dev/null | grep -q '"result":\[{' && echo "[OK] Metrics visible in Prometheus" && break
  printf "."
  sleep 1
done
echo ""

# ── tmux session ──────────────────────────────────────────────
t1_title="#[bg=colour27,fg=white,bold]   T1 — POSTMORTEM FILES / LOGS   #[default]"
t2_title="#[bg=colour46,fg=black,bold]   T2 — DEMO COMMANDS             #[default]"

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
tmux set-option -t "$session" -g status-right ""
tmux set-option -t "$session" -g status-right ""
tmux set-option -t "$session" -g status-left ""
tmux select-pane -t "$session":0.0 -T "$t1_title"
tmux select-pane -t "$session":0.1 -T "$t2_title"
tmux send-keys -t "$session":0.0 "clear" Enter
tmux send-keys -t "$session":0.1 "clear" Enter
tmux select-pane -t "$session":0.1

log "All services up — BASELINE: 2 postmortems loaded"
hr
echo ""
echo "  Exporter      : http://localhost:8090"
echo "  Prometheus    : http://localhost:9090"
echo "  Grafana       : http://localhost:3000  (admin/admin)"
echo ""
echo "  Staged        : staging/INC-2024-003.yaml  (for live addition)"
echo "  Baseline      : 2 postmortems, 5 action items"
echo ""
echo "  Navigate: Ctrl+b arrow   Detach: Ctrl+b d"
echo ""

if [[ -n "${TMUX:-}" ]]; then
  tmux switch-client -t "$session"
else
  tmux attach-session -t "$session"
fi
