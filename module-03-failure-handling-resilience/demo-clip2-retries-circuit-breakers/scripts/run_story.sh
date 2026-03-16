#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_URL="http://localhost:8000"
MODEL_URL="http://localhost:8081"
VECTOR_URL="http://localhost:8082"

ts() { date '+%H:%M:%S'; }

send_requests() {
    local count=$1
    local delay=${2:-0.5}
    for i in $(seq 1 "$count"); do
        curl -s -o /dev/null -w "  req=$i  status=%{http_code}  time=%{time_total}s\n" \
            -X POST "$APP_URL/ask" \
            -H "Content-Type: application/json" \
            -d '{"question":"What is GenAI reliability?"}' || true
        sleep "$delay"
    done
}

show_breaker() {
    echo ""
    echo "  ── Breaker Status ──"
    curl -s "$APP_URL/breaker/status" | python3 -m json.tool 2>/dev/null || echo "  (service unavailable)"
    echo ""
}

echo "╔══════════════════════════════════════════╗"
echo "║  run_story.sh — Retries & Circuit Breaker║"
echo "║  $(ts)                                ║"
echo "╚══════════════════════════════════════════╝"

# ═══════════════════════════════════════════════════════════════
# PHASE 1 — BASELINE (healthy traffic, ~30s)
# ═══════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PHASE 1: BASELINE — healthy traffic"
echo "  $(ts)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Ensure stubs are healthy
curl -s -X POST "$MODEL_URL/mode/healthy" | python3 -m json.tool
curl -s -X POST "$VECTOR_URL/mode/healthy" | python3 -m json.tool

send_requests 8 0.8
show_breaker

# ═══════════════════════════════════════════════════════════════
# PHASE 2 — INJECT TIMEOUTS (model API slow → retries → breaker)
# ═══════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PHASE 2: INJECT — model API slow (timeouts)"
echo "  $(ts)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

curl -s -X POST "$MODEL_URL/mode/slow" | python3 -m json.tool
echo "  Model stub set to SLOW mode"
echo ""

send_requests 8 1.0
show_breaker

# ═══════════════════════════════════════════════════════════════
# PHASE 3 — INJECT 429 THROTTLE (vector DB)
# ═══════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PHASE 3: INJECT — vector DB throttle (429)"
echo "  $(ts)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Keep model slow, add vector throttle
curl -s -X POST "$VECTOR_URL/mode/throttle" | python3 -m json.tool
echo "  Vector stub set to THROTTLE mode"
echo ""

send_requests 6 1.0
show_breaker

# ═══════════════════════════════════════════════════════════════
# PHASE 4 — INJECT 500 ERRORS (model API → breaker opens)
# ═══════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PHASE 4: INJECT — model API 500 errors"
echo "  $(ts)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

curl -s -X POST "$MODEL_URL/mode/error" | python3 -m json.tool
curl -s -X POST "$VECTOR_URL/mode/healthy" | python3 -m json.tool
echo "  Model stub set to ERROR mode"
echo "  Vector stub restored to HEALTHY"
echo ""

send_requests 8 0.8
show_breaker

echo ""
echo "  Breaker should now be OPEN."
echo "  Sending more requests — these will be rejected immediately."
echo ""

send_requests 4 0.5
show_breaker

# ═══════════════════════════════════════════════════════════════
# PHASE 5 — RECOVERY (model recovers → half-open → closed)
# ═══════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PHASE 5: RECOVER — model API healthy again"
echo "  $(ts)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

curl -s -X POST "$MODEL_URL/mode/healthy" | python3 -m json.tool
echo "  Model stub restored to HEALTHY"
echo ""
echo "  Waiting 12 seconds for recovery timeout..."
sleep 12
echo "  Recovery timeout elapsed. Sending probe requests."
echo ""

send_requests 6 1.0
show_breaker

echo ""
echo "  Breaker should now be CLOSED — full recovery."

# ═══════════════════════════════════════════════════════════════
# DONE
# ═══════════════════════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  DONE — All phases complete              ║"
echo "║  $(ts)                                ║"
echo "╚══════════════════════════════════════════╝"
