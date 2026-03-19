#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

PASS=0
FAIL=0
LOG=".run/validation.log"
mkdir -p .run
: > "$LOG"

check() {
  local label="$1" cmd="$2"
  local output
  output=$(eval "$cmd" 2>&1)
  if [ $? -eq 0 ]; then
    echo "[PASS] $label"
    echo "[PASS] $label" >> "$LOG"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] $label"
    echo "[FAIL] $label — $output" >> "$LOG"
    FAIL=$((FAIL + 1))
  fi
}

echo ""
echo "=========================================================="
echo " validate_demo.sh  — M4 Clip 4 Full Validation"
echo " $(date +%H:%M:%S)"
echo "=========================================================="
echo ""

echo "--- File Structure ---"
check "app/exporter.py exists" "test -f app/exporter.py"
check "app/score_backlog.py exists" "test -f app/score_backlog.py"
check "postmortems/schema.yaml" "test -f postmortems/schema.yaml"
check "postmortems/INC-2024-001.yaml" "test -f postmortems/INC-2024-001.yaml"
check "postmortems/INC-2024-002.yaml" "test -f postmortems/INC-2024-002.yaml"
check "postmortems/INC-2024-003.yaml" "test -f postmortems/INC-2024-003.yaml"
check "infra/docker-compose.yaml" "test -f infra/docker-compose.yaml"
check "infra/prometheus/prometheus.yml" "test -f infra/prometheus/prometheus.yml"
check "infra/grafana/dashboards/dashboard.json" "test -f infra/grafana/dashboards/dashboard.json"
check "requirements.txt" "test -f requirements.txt"

echo ""
echo "--- Python Syntax ---"
check "exporter.py syntax valid" "python3 -c \"import ast; ast.parse(open('app/exporter.py').read())\""
check "score_backlog.py syntax valid" "python3 -c \"import ast; ast.parse(open('app/score_backlog.py').read())\""

echo ""
echo "--- Shell Syntax ---"
check "demo_up.sh syntax" "bash -n scripts/demo_up.sh"
check "demo_down.sh syntax" "bash -n scripts/demo_down.sh"
check "preflight_check.sh syntax" "bash -n scripts/preflight_check.sh"

echo ""
echo "--- YAML Validation ---"
check "INC-001 YAML valid" "python3 -c \"import yaml; d=yaml.safe_load(open('postmortems/INC-2024-001.yaml')); assert d['severity'] in ('SEV1','SEV2','SEV3')\""
check "INC-002 YAML valid" "python3 -c \"import yaml; d=yaml.safe_load(open('postmortems/INC-2024-002.yaml')); assert d['severity'] in ('SEV1','SEV2','SEV3')\""
check "INC-003 YAML valid" "python3 -c \"import yaml; d=yaml.safe_load(open('postmortems/INC-2024-003.yaml')); assert d['severity'] in ('SEV1','SEV2','SEV3')\""
check "INC-001 has root_cause_category" "python3 -c \"import yaml; d=yaml.safe_load(open('postmortems/INC-2024-001.yaml')); assert d['root_cause_category'] == 'retrieval_cascade'\""
check "INC-002 has root_cause_category" "python3 -c \"import yaml; d=yaml.safe_load(open('postmortems/INC-2024-002.yaml')); assert d['root_cause_category'] == 'model_timeout'\""
check "INC-003 has root_cause_category" "python3 -c \"import yaml; d=yaml.safe_load(open('postmortems/INC-2024-003.yaml')); assert d['root_cause_category'] == 'retrieval_cascade'\""
check "INC-001 has action_items" "python3 -c \"import yaml; d=yaml.safe_load(open('postmortems/INC-2024-001.yaml')); assert len(d['action_items']) == 3\""
check "INC-003 has scoring fields" "python3 -c \"import yaml; d=yaml.safe_load(open('postmortems/INC-2024-003.yaml')); ai=d['action_items'][0]; assert all(k in ai for k in ('impact','likelihood','effort'))\""

echo ""
echo "--- Repeat Incident Pattern ---"
check "Two retrieval_cascade incidents" "python3 -c \"
import yaml, glob
cats = [yaml.safe_load(open(f))['root_cause_category'] for f in sorted(glob.glob('postmortems/INC-*.yaml'))]
assert cats.count('retrieval_cascade') == 2, f'Expected 2, got {cats.count(\"retrieval_cascade\")}'
\""

echo ""
echo "--- Dashboard JSON ---"
check "Dashboard has 8 panels" "python3 -c \"import json; d=json.load(open('infra/grafana/dashboards/dashboard.json')); assert len(d['panels']) == 8, f'Expected 8, got {len(d[\"panels\"])}'\""
check "Dashboard title is Operational Excellence" "python3 -c \"import json; d=json.load(open('infra/grafana/dashboards/dashboard.json')); assert d['title'] == 'Operational Excellence'\""

echo ""
echo "----------------------------------------------------------"
TOTAL=$((PASS + FAIL))
echo ""
echo "  ${PASS} passed   ${FAIL} failed"
echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "  ${FAIL} CHECK(S) FAILED — FIX BEFORE BUILDING"
else
  echo "  ALL ${TOTAL} CHECKS PASSED — READY TO BUILD"
fi
echo ""
