#!/usr/bin/env bash
# =============================================================================
# validate_demo.sh — Run every demo scene and dump all output to log
# Usage: bash scripts/validate_demo.sh 2>&1 | tee .run/validation.log
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="http://localhost:8000"
MODEL="http://localhost:8081"
VECTOR="http://localhost:8082"

log() {
  printf "\n\n════════════════════════════════════════════════════════\n"
  printf "  %s  %s\n" "$(date +%H:%M:%S)" "$1"
  printf "════════════════════════════════════════════════════════\n"
}
sep() { printf "\n── %s ──\n" "$1"; }

restart_app() {
  printf "\n[restart] Killing app and restarting with fresh state...\n"
  [ -f .run/app.pid ] && kill "$(cat .run/app.pid)" 2>/dev/null || true
  pids=$(lsof -ti tcp:8000 2>/dev/null || true)
  [ -n "$pids" ] && echo "$pids" | while read -r p; do kill -9 "$p" 2>/dev/null || true; done
  sleep 1
  nohup .venv/bin/python -m uvicorn app.main:app \
    --host 0.0.0.0 --port 8000 --log-level warning \
    >> .run/app.log 2>&1 & echo $! > .run/app.pid
  for i in $(seq 1 20); do
    curl -sf http://localhost:8000/health >/dev/null 2>&1 && break
    sleep 0.5
  done
  curl -s -X POST "$MODEL/mode/healthy" > /dev/null
  curl -s -X POST "$VECTOR/mode/healthy" > /dev/null
  printf "[restart] Done — breaker CLOSED, budget empty, stubs healthy\n"
}

# ── Start clean ───────────────────────────────────────────────────────────────
restart_app

# =============================================================================
log "SCENE 1 — Time Budgets Fire"
# =============================================================================
sep "Config: MODEL_TIMEOUT_S and VECTOR_TIMEOUT_S"
grep "MODEL_TIMEOUT_S\|VECTOR_TIMEOUT_S" app/main.py | grep "^MODEL\|^VECTOR"

sep "Set model → slow then POST /ask"
curl -s -X POST "$MODEL/mode/slow" > /dev/null && echo "model=slow"
curl -s -X POST "$APP/ask" \
  -H 'content-type: application/json' \
  -d '{"question":"budget test"}' | python3 -m json.tool || true

sep "App log tail (MUST show: reason=timeout retryable=True AND RETRY lines)"
tail -15 .run/app.log

# =============================================================================
log "SCENE 2 — Backoff, Retry Limits, Retry Budget"
# =============================================================================
sep "Set model → throttle (429) then POST /ask"
curl -s -X POST "$MODEL/mode/throttle" > /dev/null && echo "model=throttle"
curl -s -X POST "$APP/ask" \
  -H 'content-type: application/json' \
  -d '{"question":"backoff test"}' | python3 -m json.tool || true

sep "App log tail (MUST show: attempt=0→1, 1→2, 2→3 with different backoff values)"
tail -20 .run/app.log

sep "Breaker status (MUST be: state CLOSED, failure_count > 0)"
curl -s "$APP/breaker/status" | python3 -m json.tool

# =============================================================================
log "SCENE 3 — Safe Failure Class Allow-List"
# =============================================================================
sep "Code: RETRYABLE_STATUS_CODES and _is_retryable (MUST be visible)"
grep -A8 "RETRYABLE_STATUS_CODES\|def _is_retryable" app/main.py | head -14

# =============================================================================
log "SCENE 4 — Baseline + Breaker OPEN + Fast-Fail + Bulkhead"
# =============================================================================
sep "Baseline: model → healthy, send 1 request (MUST succeed)"
curl -s -X POST "$MODEL/mode/healthy" > /dev/null && echo "model=healthy"
curl -s -X POST "$APP/ask" \
  -H 'content-type: application/json' \
  -d '{"question":"What is an SLO?"}' | python3 -m json.tool

sep "Set model → error (500), send 7 requests to trip breaker"
curl -s -X POST "$MODEL/mode/error" > /dev/null && echo "model=error"
for i in {1..7}; do
  printf "\n--- request %d ---\n" "$i"
  curl -s -X POST "$APP/ask" \
    -H 'content-type: application/json' \
    -d '{"question":"trip"}' | python3 -m json.tool || true
  sleep 0.3
done

sep "App log tail (MUST show: CLOSED → OPEN and OPEN — request rejected)"
tail -25 .run/app.log

sep "Breaker status (MUST be: model_api OPEN, vector_db CLOSED)"
curl -s "$APP/breaker/status" | python3 -m json.tool

sep "Fast-fail: 3 requests while OPEN (MUST be < 300ms each)"
for i in {1..3}; do
  printf "\n--- fast-fail %d ---\n" "$i"
  START=$(python3 -c "import time; print(time.time())")
  curl -s -X POST "$APP/ask" \
    -H 'content-type: application/json' \
    -d '{"question":"fast fail?"}' | python3 -m json.tool || true
  END=$(python3 -c "import time; print(time.time())")
  python3 -c "
elapsed = float(${END}) - float(${START})
status = '✅ PASS' if elapsed < 0.300 else '❌ FAIL'
print(f'  elapsed: {elapsed:.3f}s  {status}')
"
done

# =============================================================================
# RESTART between scene 4 and 5 — fresh breaker + fresh budget
# =============================================================================
restart_app

# =============================================================================
log "SCENE 5 — Half-Open Recovery"
# =============================================================================
sep "Trip breaker cleanly: model → error, send 6 requests"
curl -s -X POST "$MODEL/mode/error" > /dev/null && echo "model=error"
for i in {1..6}; do
  curl -s -X POST "$APP/ask" \
    -H 'content-type: application/json' \
    -d '{"question":"trip"}' | python3 -m json.tool > /dev/null || true
  sleep 0.2
done
printf "Breaker state after trip:\n"
curl -s "$APP/breaker/status" | python3 -m json.tool

sep "Restore model → healthy. Waiting 12s for recovery timeout."
curl -s -X POST "$MODEL/mode/healthy" > /dev/null && echo "model=healthy"
echo "Waiting 12s..."
sleep 12

sep "Send 4 probes — MUST show OPEN→HALF_OPEN→probe 1/2→probe 2/2→CLOSED"
for i in {1..4}; do
  printf "\n--- probe %d ---\n" "$i"
  curl -s -X POST "$APP/ask" \
    -H 'content-type: application/json' \
    -d '{"question":"probe"}' | python3 -m json.tool || true
  sleep 0.8
done

sep "App log tail (MUST contain all 4 transition lines)"
tail -20 .run/app.log

sep "Final breaker status (MUST be: both CLOSED, failure_count 0)"
curl -s "$APP/breaker/status" | python3 -m json.tool

# =============================================================================
log "SCENE 6 — Prometheus Proof"
# =============================================================================
sep "genai_circuit_breaker_transitions_total (MUST include closed→open and half_open→closed)"
curl -s "http://localhost:9090/api/v1/query?query=genai_circuit_breaker_transitions_total" \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
results=d.get('data',{}).get('result',[])
print(f'  {len(results)} series found')
for r in results:
  m=r['metric']
  print(f'    {m.get(\"from_state\")} → {m.get(\"to_state\")}  count={r[\"value\"][1]}')
" 2>/dev/null || echo "  (Prometheus not reachable)"

sep "genai_retries_total by reason (MUST show timeout, 429, 5xx)"
curl -s "http://localhost:9090/api/v1/query?query=genai_retries_total" \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
results=d.get('data',{}).get('result',[])
print(f'  {len(results)} series found')
for r in results:
  m=r['metric']
  print(f'    dep={m.get(\"dependency\")} reason={m.get(\"reason\")} count={r[\"value\"][1]}')
" 2>/dev/null || echo "  (Prometheus not reachable)"

# =============================================================================
log "AUTO PASS/FAIL SUMMARY"
# =============================================================================
printf "\n"
PASS=0; FAIL=0

chk() {
  local label="$1" pattern="$2"
  if grep -q "$pattern" .run/app.log 2>/dev/null; then
    printf "  ✅  %s\n" "$label"; PASS=$((PASS+1))
  else
    printf "  ❌  %s\n" "$label"; FAIL=$((FAIL+1))
  fi
}

chk "Scene 1 — reason=timeout retryable=True"    "reason=timeout  retryable=True"
chk "Scene 2 — backoff attempt=0→1"              "attempt=0→1"
chk "Scene 2 — backoff attempt=1→2"              "attempt=1→2"
chk "Scene 2 — backoff attempt=2→3"              "attempt=2→3"
chk "Scene 4 — CLOSED → OPEN"                   "CLOSED → OPEN"
chk "Scene 4 — OPEN — request rejected"          "OPEN — request rejected"
chk "Scene 5 — OPEN → HALF_OPEN"                "OPEN → HALF_OPEN"
chk "Scene 5 — half-open probe OK (1/2)"         "probe OK (1/2)"
chk "Scene 5 — half-open probe OK (2/2)"         "probe OK (2/2)"
chk "Scene 5 — HALF_OPEN → CLOSED"              "HALF_OPEN → CLOSED"

printf "\n  ────────────────────────────────────────────────\n"
printf "  RESULT: %d/10 passed · %d failed\n" "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  printf "  ✅  ALL PROOF POINTS CONFIRMED — READY TO RECORD\n"
else
  printf "  ❌  %d PROOF POINT(S) MISSING — DO NOT RECORD YET\n" "$FAIL"
fi
printf "  ────────────────────────────────────────────────\n\n"
