#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
LOG_FILE="$ROOT/.run/preflight_${TIMESTAMP}.log"
HTML_FILE="$ROOT/.run/preflight_report.html"
mkdir -p "$ROOT/.run"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; RESET='\033[0m'
pass(){ echo -e "${GREEN}✓${RESET} $1"; }
fail(){ echo -e "${RED}✗${RESET} $1"; }
warn(){ echo -e "${YELLOW}⚠${RESET} $1"; }

declare -a CHECK_NAMES=()
declare -a CHECK_STATUS=()
declare -a CHECK_DETAIL=()
declare -a CHECK_FIX=()
FAIL_COUNT=0

record(){
  CHECK_NAMES+=("$1"); CHECK_STATUS+=("$2")
  CHECK_DETAIL+=("$3"); CHECK_FIX+=("$4")
  [ "$2" = "FAIL" ] && (( FAIL_COUNT++ )) || true
}

exec > >(tee -a "$LOG_FILE") 2>&1

echo "════════════════════════════════════════════════════════"
echo " Pre-flight — Mod 3 Clip 2: Retries and Circuit Breakers"
echo " $(date)"
echo "════════════════════════════════════════════════════════"
echo ""

# ── CHECK 1: Python ───────────────────────────────────────────────────────────
echo "── [1/8] Python version ──"
if command -v python3 >/dev/null 2>&1; then
  PY_VER=$(python3 --version 2>&1)
  pass "$PY_VER"
  record "Python" "PASS" "$PY_VER" ""
else
  fail "python3 not found"
  record "Python" "FAIL" "python3 not in PATH" "brew install python@3.12"
fi
echo ""

# ── CHECK 2: Docker ───────────────────────────────────────────────────────────
echo "── [2/8] Docker daemon ──"
if docker info >/dev/null 2>&1; then
  VER=$(docker info 2>/dev/null | grep "Server Version" | awk '{print $3}')
  pass "Docker $VER"
  record "Docker" "PASS" "Docker $VER running" ""
else
  fail "Docker not running"
  record "Docker" "FAIL" "Docker Desktop not started" \
    "Open Docker Desktop and wait for the whale icon to stop animating"
fi
echo ""

# ── CHECK 3: Venv + deps ──────────────────────────────────────────────────────
echo "── [3/8] Venv and dependencies ──"
if [ -f "$ROOT/.venv/bin/python" ]; then
  if "$ROOT/.venv/bin/python" -c "import fastapi, uvicorn, httpx, prometheus_client" 2>/dev/null; then
    pass "All packages importable"
    record "Venv and deps" "PASS" "fastapi uvicorn httpx prometheus_client all importable" ""
  else
    fail "One or more packages missing"
    record "Venv and deps" "FAIL" "venv exists but packages missing" \
      "Run: .venv/bin/python -m pip install -r requirements.txt"
  fi
else
  fail ".venv not found"
  record "Venv and deps" "FAIL" "No .venv found" "Run ./scripts/demo_up.sh"
fi
echo ""

# ── CHECK 4: App health ───────────────────────────────────────────────────────
echo "── [4/8] App /health (:8000) ──"
HEALTH=$(curl -sf --max-time 4 localhost:8000/health 2>/dev/null)
if echo "$HEALTH" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'status' in d" 2>/dev/null; then
  MB=$(echo "$HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin)['model_breaker'])")
  VB=$(echo "$HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin)['vector_breaker'])")
  pass "status=ok  model_breaker=$MB  vector_breaker=$VB"
  record "App /health" "PASS" "model_breaker=$MB vector_breaker=$VB" ""
else
  fail "App not responding"
  record "App /health" "FAIL" "${HEALTH:0:120}" \
    "Run ./scripts/demo_up.sh and wait for 'Up.' message. Check: cat .run/app.log"
fi
echo ""

# ── CHECK 5: Stubs ────────────────────────────────────────────────────────────
echo "── [5/8] Dependency stubs ──"
MODEL_MODE=$(curl -sf --max-time 3 localhost:8081/mode 2>/dev/null)
if echo "$MODEL_MODE" | grep -q '"mode"'; then
  MODE=$(echo "$MODEL_MODE" | python3 -c "import sys,json; print(json.load(sys.stdin)['mode'])")
  pass "model-stub :8081  mode=$MODE"
  record "Model stub" "PASS" "mode=$MODE" ""
else
  fail "model-stub :8081 not responding"
  record "Model stub" "FAIL" "${MODEL_MODE:0:80}" "Run ./scripts/demo_up.sh. Check: cat .run/model.log"
fi

VECTOR_MODE=$(curl -sf --max-time 3 localhost:8082/mode 2>/dev/null)
if echo "$VECTOR_MODE" | grep -q '"mode"'; then
  MODE=$(echo "$VECTOR_MODE" | python3 -c "import sys,json; print(json.load(sys.stdin)['mode'])")
  pass "vector-stub :8082  mode=$MODE"
  record "Vector stub" "PASS" "mode=$MODE" ""
else
  fail "vector-stub :8082 not responding"
  record "Vector stub" "FAIL" "${VECTOR_MODE:0:80}" "Run ./scripts/demo_up.sh. Check: cat .run/vector.log"
fi
echo ""

# ── CHECK 6: End-to-end ───────────────────────────────────────────────────────
echo "── [6/8] End-to-end /ask ──"
CHAT=$(curl -sf --max-time 10 -X POST localhost:8000/ask \
  -H 'content-type: application/json' \
  -d '{"question":"preflight check"}' 2>/dev/null)
if echo "$CHAT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'answer' in d" 2>/dev/null; then
  MB=$(echo "$CHAT" | python3 -c "import sys,json; print(json.load(sys.stdin)['model_breaker'])")
  LAT=$(echo "$CHAT" | python3 -c "import sys,json; print(json.load(sys.stdin)['latency_ms'])")
  pass "answer returned  model_breaker=$MB  latency=${LAT}ms"
  record "End-to-end /ask" "PASS" "model_breaker=$MB latency=${LAT}ms" ""
else
  fail "POST /ask failed"
  record "End-to-end /ask" "FAIL" "${CHAT:0:120}" \
    "Check .run/app.log .run/model.log .run/vector.log"
fi
echo ""

# ── CHECK 7: Prometheus ───────────────────────────────────────────────────────
echo "── [7/8] Prometheus (:9090) ──"
PROM=$(curl -sf --max-time 5 localhost:9090/-/healthy 2>/dev/null)
if echo "$PROM" | grep -q "Prometheus"; then
  pass "Prometheus healthy"
  record "Prometheus" "PASS" "Responding at :9090" ""
else
  fail "Prometheus not responding"
  record "Prometheus" "FAIL" "Not healthy" \
    "docker compose -f infra/docker-compose.yaml up -d"
fi
echo ""

# ── CHECK 8: Grafana ─────────────────────────────────────────────────────────
echo "── [8/8] Grafana (:3000) ──"
GRAF=$(curl -sf --max-time 5 localhost:3000/api/health 2>/dev/null)
if echo "$GRAF" | grep -q "ok"; then
  pass "Grafana healthy — http://localhost:3000  (admin/admin)"
  record "Grafana" "PASS" "Accessible at localhost:3000" ""
else
  fail "Grafana not responding"
  record "Grafana" "FAIL" "Not healthy" \
    "docker compose -f infra/docker-compose.yaml up -d grafana"
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
PASS_COUNT=0; WARN_COUNT=0
for s in "${CHECK_STATUS[@]}"; do
  [ "$s" = "PASS" ] && (( PASS_COUNT++ )) || true
  [ "$s" = "WARN" ] && (( WARN_COUNT++ )) || true
done
TOTAL=${#CHECK_NAMES[@]}

echo "════════════════════════════════════════════════════════"
echo " SUMMARY: $PASS_COUNT/$TOTAL passed  |  $FAIL_COUNT failed  |  $WARN_COUNT warnings"
echo "════════════════════════════════════════════════════════"

# ── HTML report ───────────────────────────────────────────────────────────────
STATUS_COLOR(){ case "$1" in PASS) echo "#1a7f37";; FAIL) echo "#d1242f";; WARN) echo "#9a6700";; esac }
STATUS_BG(){    case "$1" in PASS) echo "#dafbe1";; FAIL) echo "#ffebe9";; WARN) echo "#fff8c5";; esac }
STATUS_ICON(){  case "$1" in PASS) echo "✓";; FAIL) echo "✗";; WARN) echo "⚠";; esac }

OVERALL_COLOR="#1a7f37"; OVERALL_TEXT="ALL CHECKS PASSED — READY TO RECORD"
[ $FAIL_COUNT -gt 0 ] && OVERALL_COLOR="#d1242f" && OVERALL_TEXT="CHECKS FAILED — FIX BEFORE RECORDING"

ROWS_HTML=""
for i in "${!CHECK_NAMES[@]}"; do
  st="${CHECK_STATUS[$i]}"
  color=$(STATUS_COLOR "$st"); bg=$(STATUS_BG "$st"); icon=$(STATUS_ICON "$st")
  fix_html=""
  [ -n "${CHECK_FIX[$i]}" ] && \
    fix_html="<div style='margin-top:8px;padding:8px 10px;background:#f6f8fa;border-left:3px solid ${color};border-radius:4px;font-size:13px'><strong>Fix:</strong> ${CHECK_FIX[$i]}</div>"
  ROWS_HTML+="<tr style='border-bottom:1px solid #e6e6e6'>
    <td style='padding:12px 16px;vertical-align:top;white-space:nowrap'>
      <span style='font-weight:700;color:${color};font-size:16px'>${icon}</span>
      <span style='display:inline-block;padding:2px 8px;border-radius:12px;font-size:12px;font-weight:600;background:${bg};color:${color};margin-left:6px'>${st}</span>
    </td>
    <td style='padding:12px 16px;vertical-align:top;font-weight:600'>${CHECK_NAMES[$i]}</td>
    <td style='padding:12px 16px;vertical-align:top;color:#555;font-size:13px'>${CHECK_DETAIL[$i]}${fix_html}</td>
  </tr>"
done

cat > "$HTML_FILE" << HTMLEOF
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
<title>Pre-flight — Mod 3 Clip 2</title>
<style>* { box-sizing:border-box;margin:0;padding:0 }
body { font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#f6f8fa;color:#1f2328;padding:32px }
.card { background:white;border-radius:8px;border:1px solid #d0d7de;max-width:960px;margin:0 auto;overflow:hidden }
.header { padding:24px 32px;border-bottom:1px solid #d0d7de }
.badge { display:inline-block;padding:6px 16px;border-radius:20px;font-weight:700;font-size:14px;color:white;background:${OVERALL_COLOR};margin-top:8px }
.meta { color:#666;font-size:13px;margin-top:6px }
table { width:100%;border-collapse:collapse }
th { padding:10px 16px;text-align:left;background:#f6f8fa;font-size:12px;text-transform:uppercase;letter-spacing:.05em;color:#666;border-bottom:2px solid #d0d7de }
.footer { padding:16px 32px;background:#f6f8fa;border-top:1px solid #d0d7de;font-size:12px;color:#666 }
code { background:#f3f4f5;padding:1px 5px;border-radius:4px;font-family:'SF Mono',Consolas,monospace;font-size:12px }</style>
</head><body><div class="card">
  <div class="header">
    <div style="font-size:20px;font-weight:700">Pre-flight Check — Mod 3 Clip 2</div>
    <div style="font-size:13px;color:#666;margin-top:2px">Retries and Circuit Breakers with HTTPX</div>
    <div class="badge">${OVERALL_TEXT}</div>
    <div class="meta">$(date) &nbsp;·&nbsp; ${PASS_COUNT}/${TOTAL} passed &nbsp;·&nbsp; ${FAIL_COUNT} failed &nbsp;·&nbsp; Log: <code>$(basename "$LOG_FILE")</code></div>
  </div>
  <table><thead><tr>
    <th style="width:130px">Status</th>
    <th style="width:180px">Check</th>
    <th>Detail &amp; Fix</th>
  </tr></thead><tbody>${ROWS_HTML}</tbody></table>
  <div class="footer">Log: <code>${LOG_FILE}</code></div>
</div></body></html>
HTMLEOF

echo ""
echo "HTML report → $HTML_FILE"
echo "Log         → $LOG_FILE"
echo ""
command -v open >/dev/null 2>&1 && open "$HTML_FILE" || true
exit $FAIL_COUNT
