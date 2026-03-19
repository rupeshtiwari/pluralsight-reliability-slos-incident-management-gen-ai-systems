#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PASS=0
FAIL=0

check() {
  local label="$1" cmd="$2"
  if eval "$cmd" >/dev/null 2>&1; then
    echo "[PASS] $label"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] $label"
    FAIL=$((FAIL + 1))
  fi
}

echo ""
echo "=========================================================="
echo " preflight_check.sh  — M4 Clip 2 Alerting Demo"
echo " $(date +%H:%M:%S)"
echo "=========================================================="
echo ""

# App and stubs
check "App :8000 healthy" "curl -sf localhost:8000/health"
check "App /metrics available" "curl -sf localhost:8000/metrics | grep -q genai_requests_total"
check "Model stub :8081" "curl -sf localhost:8081/mode"
check "Vector stub :8082" "curl -sf localhost:8082/mode"
check "Webhook stub :5001" "curl -sf localhost:5001/health"
check "POST /ask returns 200" "curl -sf -X POST localhost:8000/ask -H 'content-type: application/json' -d '{\"question\":\"test\"}'"

# Prometheus
check "Prometheus :9090 ready" "curl -sf localhost:9090/-/ready"
check "Prometheus rules loaded" "curl -sf localhost:9090/api/v1/rules | grep -q SLOBurnRateCritical"
check "Prometheus scraping app" "curl -sf -G localhost:9090/api/v1/query --data-urlencode 'query=up{job=\"genai-service\"}' | grep -q '\"1\"'"

# Alertmanager
check "Alertmanager :9093 ready" "curl -sf localhost:9093/-/ready"
check "Alertmanager config loaded" "curl -sf localhost:9093/api/v2/status | grep -q pagerduty-critical"

# Grafana
check "Grafana :3000 healthy" "curl -sf localhost:3000/api/health | grep -q ok"

echo ""
echo "----------------------------------------------------------"
TOTAL=$((PASS + FAIL))
echo ""
echo "  ${PASS} passed   ${FAIL} failed"
echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "  ${FAIL} CHECK(S) FAILED — FIX BEFORE RECORDING"
else
  echo "  ALL ${TOTAL} CHECKS PASSED — READY TO RECORD"
fi
echo ""
