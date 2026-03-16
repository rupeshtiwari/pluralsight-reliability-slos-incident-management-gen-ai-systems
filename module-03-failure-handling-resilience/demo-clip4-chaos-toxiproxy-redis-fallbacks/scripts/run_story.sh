#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="http://localhost:8000"
ts() { date '+%H:%M:%S'; }

send() {
  local count=$1 delay=${2:-0.5}
  for i in $(seq 1 "$count"); do
    curl -s -o /dev/null -w "  req=$i  status=%{http_code}  time=%{time_total}s\n" \
      -X POST "$APP/ask" \
      -H "Content-Type: application/json" \
      -d '{"question":"What is an SLO?"}' || true
    sleep "$delay"
  done
}

echo "========================================================"
echo "  run_story.sh  — Clip 4 Chaos + Fallback Story"
echo "  $(ts)"
echo "========================================================"

# PHASE 1 — Baseline
echo ""
echo "  PHASE 1: BASELINE — healthy traffic"
bash scripts/clear_toxics.sh all > /dev/null 2>&1 || true
send 6 0.5

# PHASE 2 — Vector latency -> cache fallback
echo ""
echo "  PHASE 2: INJECT — vector latency 2500ms"
bash scripts/set_toxic.sh vector latency 2500 > /dev/null
send 6 1.0
bash scripts/clear_toxics.sh vector > /dev/null

# PHASE 3 — Model reset -> cache fallback
echo ""
echo "  PHASE 3: INJECT — model connection reset"
bash scripts/set_toxic.sh model reset_peer 0 > /dev/null
send 4 1.0
bash scripts/clear_toxics.sh model > /dev/null

# PHASE 4 — Idempotency
echo ""
echo "  PHASE 4: IDEMPOTENCY — duplicate tool calls"
for key in idem-story-001 idem-story-002; do
  curl -s -o /dev/null -X POST "$APP/tool" \
    -H "Content-Type: application/json" \
    -H "Idempotency-Key: ${key}" \
    -d '{"action":"book_meeting","params":{"time":"3pm"}}' || true
  # Send same key again
  curl -s -o /dev/null -X POST "$APP/tool" \
    -H "Content-Type: application/json" \
    -H "Idempotency-Key: ${key}" \
    -d '{"action":"book_meeting","params":{"time":"3pm"}}' || true
done
echo "  Idempotency keys sent"

# PHASE 5 — Combined chaos
echo ""
echo "  PHASE 5: COMBINED — both dependencies under pressure"
bash scripts/set_toxic.sh vector latency 2000 > /dev/null
bash scripts/set_toxic.sh model bandwidth 10 > /dev/null
send 8 0.8
bash scripts/clear_toxics.sh all > /dev/null

# PHASE 6 — Recovery
echo ""
echo "  PHASE 6: RECOVERY — clean traffic"
send 6 0.5

echo ""
echo "========================================================"
echo "  DONE — All phases complete"
echo "  Open Grafana: http://localhost:3000"
echo "  $(ts)"
echo "========================================================"
