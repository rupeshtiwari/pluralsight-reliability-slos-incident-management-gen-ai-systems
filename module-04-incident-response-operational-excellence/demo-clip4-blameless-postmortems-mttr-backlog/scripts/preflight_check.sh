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
echo " preflight_check.sh  — M4 Clip 4 Operational Excellence"
echo " $(date +%H:%M:%S)"
echo "=========================================================="
echo ""

# Exporter — baseline is 2 postmortems (INC-003 staged)
check "Exporter :8090 healthy" "curl -sf localhost:8090/health"
check "Exporter /metrics available" "curl -sf localhost:8090/metrics | grep -q incident_total"
check "Exporter loads 2 postmortems (baseline)" "curl -sf localhost:8090/postmortems | grep -q '\"count\":2'"

# Prometheus
check "Prometheus :9090 ready" "curl -sf localhost:9090/-/ready"
check "Prometheus scraping exporter" "curl -sf -G localhost:9090/api/v1/query --data-urlencode 'query=incident_total' | grep -q '\"result\":\[{'"
check "Prometheus has MTTR data" "curl -sf -G localhost:9090/api/v1/query --data-urlencode 'query=incident_mttr_seconds' | grep -q '\"result\":\[{'"
check "Prometheus has toil data" "curl -sf -G localhost:9090/api/v1/query --data-urlencode 'query=operational_toil_hours' | grep -q '\"result\":\[{'"
check "Prometheus has repeat data" "curl -sf -G localhost:9090/api/v1/query --data-urlencode 'query=repeat_incident_total' | grep -q '\"result\":\[{'"

# Grafana
check "Grafana :3000 healthy" "curl -sf localhost:3000/api/health | grep -q ok"
check "Dashboard provisioned" "curl -sf localhost:3000/api/dashboards/uid/operational-excellence | grep -q 'Operational Excellence'"

# Postmortem files — baseline
check "INC-2024-001.yaml in postmortems/" "test -f postmortems/INC-2024-001.yaml"
check "INC-2024-002.yaml in postmortems/" "test -f postmortems/INC-2024-002.yaml"
check "INC-2024-003.yaml staged (NOT in postmortems)" "test ! -f postmortems/INC-2024-003.yaml"
check "INC-2024-003.yaml in staging/" "test -f staging/INC-2024-003.yaml"
check "schema.yaml exists" "test -f postmortems/schema.yaml"

# Demo scripts
check "show_postmortem.py exists" "test -f app/show_postmortem.py"
check "score_backlog.py runs (2 postmortems)" ".venv/bin/python app/score_backlog.py --postmortem-dir postmortems 2>&1 | grep -q 'RELIABILITY BACKLOG'"

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
