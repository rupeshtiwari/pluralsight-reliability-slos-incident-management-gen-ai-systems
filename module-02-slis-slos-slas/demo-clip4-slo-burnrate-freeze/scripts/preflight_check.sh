#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# preflight_check.sh — Demo Clip 4 pre-flight health check
# Runs all service checks, writes an HTML report + a single log file.
# Usage: ./scripts/preflight_check.sh
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
LOG_FILE="$ROOT/.run/preflight_${TIMESTAMP}.log"
HTML_FILE="$ROOT/.run/preflight_report.html"
mkdir -p "$ROOT/.run"

# ── Colour helpers (terminal only) ───────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; RESET='\033[0m'
pass(){ echo -e "${GREEN}✓${RESET} $1"; }
fail(){ echo -e "${RED}✗${RESET} $1"; }
warn(){ echo -e "${YELLOW}⚠${RESET} $1"; }

# ── Result tracking ───────────────────────────────────────────────────────────
declare -a CHECK_NAMES=()
declare -a CHECK_STATUS=()
declare -a CHECK_DETAIL=()
declare -a CHECK_FIX=()
FAIL_COUNT=0

record(){
  local name="$1" status="$2" detail="$3" fix="$4"
  CHECK_NAMES+=("$name")
  CHECK_STATUS+=("$status")
  CHECK_DETAIL+=("$detail")
  CHECK_FIX+=("$fix")
  [ "$status" = "FAIL" ] && (( FAIL_COUNT++ )) || true
}

# ── Log everything ────────────────────────────────────────────────────────────
exec > >(tee -a "$LOG_FILE") 2>&1

echo "════════════════════════════════════════════════════════"
echo " Pre-flight check — Demo Clip 4: SLO Dashboards"
echo " $(date)"
echo " Log: $LOG_FILE"
echo "════════════════════════════════════════════════════════"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# CHECK 1 — Docker daemon
# ─────────────────────────────────────────────────────────────────────────────
echo "── [1/9] Docker daemon ──"
if docker info >/dev/null 2>&1; then
  VER=$(docker info 2>/dev/null | grep "Server Version" | awk '{print $3}')
  pass "Docker running (version $VER)"
  record "Docker daemon" "PASS" "Docker $VER is running" ""
else
  fail "Docker daemon not running"
  record "Docker daemon" "FAIL" \
    "Cannot connect to Docker socket. Docker Desktop is not started." \
    "Open Docker Desktop from Applications and wait for the menu bar whale icon to stop animating. Then run: unset DOCKER_HOST && docker context use desktop-linux"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# CHECK 2 — Ports
# PASS : port free (stack not yet started)
# PASS : port held by a known demo process (Python/uvicorn/docker/grafana/prometheus)
# FAIL : port held by a foreign process — real conflict that will block demo_up.sh
# ─────────────────────────────────────────────────────────────────────────────
echo "── [2/9] Required ports ──"
DEMO_PROCS="Python|python|uvicorn|com.docke|docker|grafana|prometheus"
PORT_CONFLICT=false
PORT_DETAIL=""

for port in 8080 9001 9002 9003 9090 3000; do
  OCCUPIED=$(lsof -nP -iTCP:$port -sTCP:LISTEN 2>/dev/null | tail -n +2)
  if [ -z "$OCCUPIED" ]; then
    pass ":$port free"
    PORT_DETAIL="${PORT_DETAIL}:$port free. "
  else
    PROC=$(echo "$OCCUPIED" | awk 'NR==1{print $1, "PID:"$2}')
    PROC_NAME=$(echo "$OCCUPIED" | awk 'NR==1{print $1}')
    if echo "$PROC_NAME" | grep -qEi "$DEMO_PROCS"; then
      pass ":$port demo running ($PROC)"
      PORT_DETAIL="${PORT_DETAIL}:$port demo process. "
    else
      fail ":$port CONFLICT — foreign process: $PROC"
      PORT_DETAIL="${PORT_DETAIL}:$port CONFLICT $PROC. "
      PORT_CONFLICT=true
    fi
  fi
done

if $PORT_CONFLICT; then
  record "Required ports" "FAIL" \
    "Foreign process blocking a required port: $PORT_DETAIL" \
    "Find the PID: lsof -nP -iTCP:<PORT> -sTCP:LISTEN  then kill it: kill -9 <PID>  Then run: ./scripts/demo_down.sh && ./scripts/demo_up.sh"
else
  record "Required ports" "PASS" "$PORT_DETAIL" ""
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# CHECK 3 — App metrics endpoint
# ─────────────────────────────────────────────────────────────────────────────
echo "── [3/9] App metrics endpoint (:8080) ──"
METRICS=$(curl -sf --max-time 3 localhost:8080/metrics 2>/dev/null)
if echo "$METRICS" | grep -q "genai_requests_total"; then
  OUTCOME_LINES=$(echo "$METRICS" | grep "genai_requests_total{" | wc -l | tr -d ' ')
  pass "App up — genai_requests_total found ($OUTCOME_LINES outcome labels)"
  record "App :8080" "PASS" "genai_requests_total present with $OUTCOME_LINES outcome labels" ""
else
  fail "App not responding on :8080 or metrics missing"
  APP_LOG=""
  [ -f "$ROOT/.run/app.log" ] && APP_LOG=$(tail -n 20 "$ROOT/.run/app.log")
  record "App :8080" "FAIL" \
    "curl to localhost:8080/metrics failed or genai_requests_total not found. Last app log: $APP_LOG" \
    "Run ./scripts/demo_up.sh and wait for 'Up.' message. If it fails, check .run/app.log"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# CHECK 4 — Stubs
# ─────────────────────────────────────────────────────────────────────────────
echo "── [4/9] Dependency stubs ──"

check_stub(){
  local name="$1" url="$2" expected="$3" port="$4"
  RESP=$(curl -sf --max-time 3 "$url" 2>/dev/null)
  if echo "$RESP" | grep -q "$expected"; then
    pass "$name (:$port) → $RESP"
    record "$name stub" "PASS" "Responded with expected field '$expected'" ""
  else
    fail "$name (:$port) — unexpected response: ${RESP:-no response}"
    STUB_LOG=""
    [ -f "$ROOT/.run/${name}.log" ] && STUB_LOG=$(tail -n 10 "$ROOT/.run/${name}.log")
    record "$name stub" "FAIL" \
      "Expected '$expected' in response but got: ${RESP:-no response}. Log: $STUB_LOG" \
      "Run ./scripts/demo_up.sh to restart all stubs. Check .run/${name}.log for errors."
  fi
}

check_stub "model"     "http://localhost:9001/complete" "text"   9001
check_stub "retrieval" "http://localhost:9002/search"   "hit"    9002
check_stub "tools"     "http://localhost:9003/call"     "result" 9003
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# CHECK 5 — Prometheus scrape target
# Retries up to 5 times with 5s gap.
# Prometheus needs one full scrape cycle after startup (interval=2s in config)
# but Docker Desktop networking can delay host.docker.internal resolution.
# 0 active targets = config not loaded yet (keep retrying)
# >0 targets but health!=up = app not reachable (fail immediately)
# ─────────────────────────────────────────────────────────────────────────────
echo "── [5/9] Prometheus scrape target (:9090) ──"
PROM_UP=false
for attempt in 1 2 3 4 5; do
  TARGETS=$(curl -sf --max-time 5 "localhost:9090/api/v1/targets" 2>/dev/null)
  RESULT=$(echo "$TARGETS" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    targets = d.get('data',{}).get('activeTargets',[])
    if not targets:
        print('no_targets')
        sys.exit(1)
    up = [t for t in targets if t.get('health') == 'up']
    if up:
        print(f'{len(up)}/{len(targets)} up')
        sys.exit(0)
    else:
        health = targets[0].get('health','unknown')
        print(f'target_down:{health}')
        sys.exit(2)
except Exception as e:
    print(f'parse_error:{e}')
    sys.exit(3)
" 2>/dev/null || echo "no_response")

  if [[ "$RESULT" == *"up"* ]]; then
    pass "Prometheus scraping app ($RESULT)"
    PROM_UP=true
    break
  elif [[ "$RESULT" == "no_targets" ]]; then
    warn "No targets registered yet — waiting 5s (attempt $attempt/5)..."
    sleep 5
  elif [[ "$RESULT" == target_down* ]]; then
    warn "Target registered but health=$RESULT — waiting 5s (attempt $attempt/5)..."
    sleep 5
  else
    warn "Prometheus not ready ($RESULT) — waiting 5s (attempt $attempt/5)..."
    sleep 5
  fi
done

if $PROM_UP; then
  record "Prometheus scrape" "PASS" "Target health: up" ""
else
  fail "Prometheus scrape target not up after 5 attempts (25s)"
  PROM_LOG=$(docker compose -f infra/docker-compose.yaml logs prometheus 2>/dev/null | tail -n 20 || echo "Could not get Prometheus logs")
  echo "$PROM_LOG"
  record "Prometheus scrape" "FAIL" \
    "Target not healthy after 25s of retries. Last result: $RESULT. Prometheus logs: $PROM_LOG" \
    "1. Confirm app is on :8080: curl localhost:8080/metrics  2. Docker Desktop on Mac uses host.docker.internal — check it resolves: docker run --rm alpine ping -c1 host.docker.internal  3. Full restart: ./scripts/demo_down.sh && ./scripts/demo_up.sh"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# CHECK 6 — Recording rules
# ─────────────────────────────────────────────────────────────────────────────
echo "── [6/9] Recording rules ──"
RULES=$(curl -sf --max-time 3 "localhost:9090/api/v1/rules" 2>/dev/null)
REQUIRED_RULES=("slo:burnrate_5m" "slo:burnrate_1h" "slo:burnrate_30m" "slo:burnrate_6h" "slo:error_budget_remaining_demo")
RULES_MISSING=()
for rule in "${REQUIRED_RULES[@]}"; do
  if echo "$RULES" | grep -q "\"$rule\""; then
    pass "Recording rule: $rule"
  else
    fail "Missing recording rule: $rule"
    RULES_MISSING+=("$rule")
  fi
done
if [ ${#RULES_MISSING[@]} -eq 0 ]; then
  record "Recording rules" "PASS" "All 5 required recording rules loaded" ""
else
  PROM_LOG=$(docker compose -f infra/docker-compose.yaml logs prometheus 2>/dev/null | tail -n 20 || echo "Could not get logs")
  record "Recording rules" "FAIL" \
    "Missing rules: ${RULES_MISSING[*]}. Prometheus logs: $PROM_LOG" \
    "Check infra/prometheus/recording.yml for YAML syntax errors. Run: docker compose -f infra/docker-compose.yaml logs prometheus | grep -i error"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# CHECK 7 — Alert rules
# ─────────────────────────────────────────────────────────────────────────────
echo "── [7/9] Alert rules ──"
REQUIRED_ALERTS=("SLOFastBurnPage" "SLOSlowBurnTicket")
ALERTS_MISSING=()
for alert in "${REQUIRED_ALERTS[@]}"; do
  if echo "$RULES" | grep -q "\"$alert\""; then
    pass "Alert rule: $alert"
  else
    fail "Missing alert rule: $alert"
    ALERTS_MISSING+=("$alert")
  fi
done
if [ ${#ALERTS_MISSING[@]} -eq 0 ]; then
  record "Alert rules" "PASS" "SLOFastBurnPage and SLOSlowBurnTicket both loaded" ""
else
  record "Alert rules" "FAIL" \
    "Missing alerts: ${ALERTS_MISSING[*]}" \
    "Check infra/prometheus/rules.yml for YAML syntax errors. Run: docker compose -f infra/docker-compose.yaml logs prometheus | grep -i error"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# CHECK 8 — Grafana
# ─────────────────────────────────────────────────────────────────────────────
echo "── [8/9] Grafana (:3000) ──"
GRAFANA=$(curl -sf --max-time 5 "localhost:3000/api/health" 2>/dev/null)
if echo "$GRAFANA" | grep -q "ok"; then
  pass "Grafana is up"
  DASH=$(curl -sf --max-time 5 \
    "admin:admin@localhost:3000/api/search?query=SLO+Compliance" 2>/dev/null)
  if echo "$DASH" | grep -q "SLO Compliance"; then
    pass "Dashboard 'SLO Compliance: GenAI API' is provisioned"
    record "Grafana" "PASS" "Grafana up and dashboard 'SLO Compliance: GenAI API' provisioned" ""
  else
    warn "Grafana up but dashboard not found — may still be loading"
    record "Grafana" "WARN" \
      "Grafana is running but 'SLO Compliance: GenAI API' dashboard not found in search." \
      "Wait 15 seconds and run this check again. If still missing: docker compose -f infra/docker-compose.yaml restart grafana"
  fi
else
  fail "Grafana not responding on :3000"
  GRAF_LOG=$(docker compose -f infra/docker-compose.yaml logs grafana 2>/dev/null | tail -n 20 || echo "Could not get logs")
  record "Grafana" "FAIL" \
    "localhost:3000/api/health did not return ok. Grafana logs: $GRAF_LOG" \
    "Check that Docker Compose is running: docker compose -f infra/docker-compose.yaml ps. Restart with: docker compose -f infra/docker-compose.yaml restart grafana"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# CHECK 9 — End-to-end smoke test
# ─────────────────────────────────────────────────────────────────────────────
echo "── [9/9] End-to-end smoke test ──"
CHAT=$(curl -sf --max-time 5 -X POST localhost:8080/chat \
  -H 'content-type: application/json' \
  -d '{"prompt":"preflight-check"}' 2>/dev/null)
if echo "$CHAT" | grep -q "outcome"; then
  OUTCOME=$(echo "$CHAT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('outcome','?'))" 2>/dev/null)
  pass "POST /chat responded — outcome: $OUTCOME"
  record "End-to-end /chat" "PASS" "POST /chat returned outcome=$OUTCOME" ""
else
  fail "POST /chat failed — response: ${CHAT:-no response}"
  record "End-to-end /chat" "FAIL" \
    "POST to localhost:8080/chat failed or returned unexpected response: ${CHAT:-no response}" \
    "Check .run/app.log and .run/model.log and .run/retrieval.log for errors."
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Dump key logs
# ─────────────────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════"
echo " RAW LOGS (attached for debugging)"
echo "════════════════════════════════════════════════════════"
for svc in app model retrieval tools; do
  if [ -f "$ROOT/.run/${svc}.log" ]; then
    echo ""
    echo "── ${svc}.log (last 30 lines) ──"
    tail -n 30 "$ROOT/.run/${svc}.log"
  fi
done
echo ""
echo "── Prometheus logs (last 30 lines) ──"
docker compose -f infra/docker-compose.yaml logs prometheus 2>/dev/null | tail -n 30 || echo "Prometheus not running"
echo ""
echo "── Grafana logs (last 20 lines) ──"
docker compose -f infra/docker-compose.yaml logs grafana 2>/dev/null | tail -n 20 || echo "Grafana not running"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
PASS_COUNT=0; WARN_COUNT=0
for s in "${CHECK_STATUS[@]}"; do
  [ "$s" = "PASS" ] && (( PASS_COUNT++ )) || true
  [ "$s" = "WARN" ] && (( WARN_COUNT++ )) || true
done
TOTAL=${#CHECK_NAMES[@]}

echo ""
echo "════════════════════════════════════════════════════════"
echo " SUMMARY: $PASS_COUNT/$TOTAL passed  |  $FAIL_COUNT failed  |  $WARN_COUNT warnings"
echo "════════════════════════════════════════════════════════"

# ─────────────────────────────────────────────────────────────────────────────
# HTML report
# ─────────────────────────────────────────────────────────────────────────────
STATUS_COLOR() {
  case "$1" in
    PASS) echo "#1a7f37";;
    FAIL) echo "#d1242f";;
    WARN) echo "#9a6700";;
  esac
}
STATUS_BG() {
  case "$1" in
    PASS) echo "#dafbe1";;
    FAIL) echo "#ffebe9";;
    WARN) echo "#fff8c5";;
  esac
}
STATUS_ICON() {
  case "$1" in
    PASS) echo "✓";;
    FAIL) echo "✗";;
    WARN) echo "⚠";;
  esac
}

OVERALL_COLOR="#1a7f37"; OVERALL_TEXT="ALL CHECKS PASSED — READY TO RECORD"
[ $WARN_COUNT -gt 0 ] && OVERALL_COLOR="#9a6700" && OVERALL_TEXT="WARNINGS — REVIEW BEFORE RECORDING"
[ $FAIL_COUNT -gt 0 ] && OVERALL_COLOR="#d1242f" && OVERALL_TEXT="CHECKS FAILED — FIX BEFORE RECORDING"

ROWS_HTML=""
for i in "${!CHECK_NAMES[@]}"; do
  st="${CHECK_STATUS[$i]}"
  color=$(STATUS_COLOR "$st")
  bg=$(STATUS_BG "$st")
  icon=$(STATUS_ICON "$st")
  fix_html=""
  if [ -n "${CHECK_FIX[$i]}" ]; then
    fix_html="<div style='margin-top:8px;padding:8px 10px;background:#f6f8fa;border-left:3px solid ${color};border-radius:4px;font-size:13px;color:#333'><strong>Fix:</strong> ${CHECK_FIX[$i]}</div>"
  fi
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
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Pre-flight Report — Demo Clip 4</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
         background: #f6f8fa; color: #1f2328; padding: 32px; }
  .card { background: white; border-radius: 8px; border: 1px solid #d0d7de;
          max-width: 960px; margin: 0 auto; overflow: hidden; }
  .header { padding: 24px 32px; border-bottom: 1px solid #d0d7de; }
  .badge { display: inline-block; padding: 6px 16px; border-radius: 20px;
           font-weight: 700; font-size: 14px; color: white;
           background: ${OVERALL_COLOR}; margin-top: 8px; }
  .meta { color: #666; font-size: 13px; margin-top: 6px; }
  table { width: 100%; border-collapse: collapse; }
  th { padding: 10px 16px; text-align: left; background: #f6f8fa;
       font-size: 12px; text-transform: uppercase; letter-spacing: .05em;
       color: #666; border-bottom: 2px solid #d0d7de; }
  .footer { padding: 16px 32px; background: #f6f8fa; border-top: 1px solid #d0d7de;
            font-size: 12px; color: #666; }
  code { background: #f3f4f5; padding: 1px 5px; border-radius: 4px;
         font-family: 'SF Mono', Consolas, monospace; font-size: 12px; }
</style>
</head>
<body>
<div class="card">
  <div class="header">
    <div style="font-size:20px;font-weight:700">Pre-flight Check — Demo Clip 4</div>
    <div style="font-size:13px;color:#666;margin-top:2px">SLO Dashboards, Burn-Rate Alerts, and Feature Freeze Triggers</div>
    <div class="badge">${OVERALL_TEXT}</div>
    <div class="meta">
      Run at: $(date) &nbsp;·&nbsp;
      ${PASS_COUNT}/${TOTAL} passed &nbsp;·&nbsp;
      ${FAIL_COUNT} failed &nbsp;·&nbsp;
      ${WARN_COUNT} warnings &nbsp;·&nbsp;
      Log: <code>$(basename "$LOG_FILE")</code>
    </div>
  </div>
  <table>
    <thead><tr>
      <th style="width:130px">Status</th>
      <th style="width:200px">Check</th>
      <th>Detail &amp; Fix</th>
    </tr></thead>
    <tbody>${ROWS_HTML}</tbody>
  </table>
  <div class="footer">
    Log file: <code>${LOG_FILE}</code><br>
    Share the log file when asking for help — it contains all service output needed to diagnose failures.
  </div>
</div>
</body>
</html>
HTMLEOF

echo ""
echo "HTML report → $HTML_FILE"
echo "Full log    → $LOG_FILE"
echo ""

if command -v open >/dev/null 2>&1; then
  open "$HTML_FILE"
fi

exit $FAIL_COUNT
