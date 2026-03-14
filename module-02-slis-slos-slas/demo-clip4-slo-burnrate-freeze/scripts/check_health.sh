#!/usr/bin/env bash
# =============================================================================
# check_health.sh — Pre-recording demo health check
# Generates: health_report.html + health.log in the project root
#
# Usage:
#   ./scripts/check_health.sh
#
# Who runs this:
#   - Author: before every recording session
#   - Students: only when the demo fails to start (not during the lesson)
#
# NOT part of the demo flow. This is the pit crew check, not the race.
# =============================================================================

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
DEMO_NAME="$(basename "$ROOT")"
LOG_FILE="$ROOT/health.log"
HTML_FILE="$ROOT/health_report.html"

# Wipe previous run
> "$LOG_FILE"

# ── Logging helpers ──────────────────────────────────────────────────────────
log()  { echo "$1" | tee -a "$LOG_FILE"; }
logq() { echo "$1" >> "$LOG_FILE"; }          # quiet — log only, no console

# ── Result tracking ──────────────────────────────────────────────────────────
PASS=0; FAIL=0; WARN=0
declare -a RESULTS   # each entry: "STATUS|LABEL|DETAIL|FIX"

add_pass() { PASS=$((PASS+1)); RESULTS+=("PASS|$1|$2|"); }
add_fail() { FAIL=$((FAIL+1)); RESULTS+=("FAIL|$1|$2|$3"); }
add_warn() { WARN=$((WARN+1)); RESULTS+=("WARN|$1|$2|$3"); }

# ── Check helpers ────────────────────────────────────────────────────────────
port_free() {
  local port=$1
  lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null
}

http_get() {
  curl -s --max-time 4 "$1" 2>>"$LOG_FILE"
}

http_post() {
  curl -s --max-time 4 -X POST "$1" 2>>"$LOG_FILE"
}

# =============================================================================
log ""
log "============================================================"
log "  Health Check: $DEMO_NAME"
log "  $TIMESTAMP"
log "============================================================"
log ""

# ── CHECK 1: Docker ──────────────────────────────────────────────────────────
log "[1/9] Docker daemon..."
docker_out=$(docker info 2>&1)
logq "$docker_out"
if echo "$docker_out" | grep -q "Server Version"; then
  docker_ver=$(echo "$docker_out" | grep "Server Version" | awk '{print $3}')
  add_pass "Docker daemon" "Running — version $docker_ver"
  log "  ✓ Docker running ($docker_ver)"
else
  add_fail "Docker daemon" "Not running" \
    "Open Docker Desktop from Applications. Wait for the menu bar whale icon to stop animating, then re-run this script."
  log "  ✗ Docker not running"
fi

# ── CHECK 2: Ports ───────────────────────────────────────────────────────────
log "[2/9] Port availability..."
declare -A PORT_NAMES=(
  [8080]="app"
  [9001]="model-stub"
  [9002]="retrieval-stub"
  [9003]="tools-stub"
  [9090]="prometheus"
  [3000]="grafana"
)
ports_blocked=0
for port in 8080 9001 9002 9003 9090 3000; do
  occupant=$(port_free "$port")
  if [ -z "$occupant" ]; then
    add_pass "Port :$port (${PORT_NAMES[$port]})" "Free"
    log "  ✓ :$port free"
  else
    pid=$(echo "$occupant" | awk 'NR>1{print $2}' | head -1)
    proc=$(echo "$occupant" | awk 'NR>1{print $1}' | head -1)
    add_fail "Port :$port (${PORT_NAMES[$port]})" \
      "Occupied by $proc (PID $pid)" \
      "Run: kill -9 $pid — or if you want to clear ALL demo ports at once: for port in 8080 9001 9002 9003; do lsof -ti tcp:\$port | xargs kill -9 2>/dev/null; done"
    log "  ✗ :$port occupied by $proc PID $pid"
    ports_blocked=$((ports_blocked+1))
  fi
done

# ── CHECK 3: App metrics ─────────────────────────────────────────────────────
log "[3/9] App metrics endpoint (:8080)..."
metrics_out=$(http_get "http://localhost:8080/metrics")
logq "$metrics_out"
if echo "$metrics_out" | grep -q "genai_requests_total"; then
  outcome_labels=$(echo "$metrics_out" | grep "genai_requests_total{" | grep -v "^#" | wc -l | tr -d ' ')
  add_pass "App /metrics" "Responding — $outcome_labels outcome label series found"
  log "  ✓ /metrics responding ($outcome_labels outcome series)"
elif [ -z "$metrics_out" ]; then
  add_fail "App /metrics" "No response — app is not running" \
    "Run ./scripts/demo_up.sh and wait for the 'Up.' message. If it fails, check: cat .run/app.log"
  log "  ✗ /metrics no response"
else
  add_fail "App /metrics" "Response missing expected metrics" \
    "App started but metrics are not registered. Check: cat .run/app.log"
  log "  ✗ /metrics unexpected response"
fi

# ── CHECK 4: Stubs ───────────────────────────────────────────────────────────
log "[4/9] Dependency stubs..."

check_stub() {
  local name=$1 url=$2 expected=$3
  local out
  out=$(http_get "$url")
  logq "  $name → $out"
  if echo "$out" | grep -q "$expected"; then
    add_pass "Stub: $name" "$url → OK"
    log "  ✓ $name"
  else
    add_fail "Stub: $name" "$url returned: ${out:0:80}" \
      "Run ./scripts/demo_up.sh. If stub started but returns wrong data check .run/${name%%-*}.log"
    log "  ✗ $name — got: ${out:0:80}"
  fi
}

check_stub "model-stub  (:9001)"     "http://localhost:9001/complete" "ok"
check_stub "retrieval-stub (:9002)"  "http://localhost:9002/search"   "hit"
check_stub "tools-stub (:9003)"      "http://localhost:9003/call"     "ok"

# ── CHECK 5: Prometheus scrape target ────────────────────────────────────────
log "[5/9] Prometheus scrape target..."
targets_out=$(http_get "http://localhost:9090/api/v1/targets")
logq "$targets_out"
if echo "$targets_out" | grep -q '"health":"up"'; then
  add_pass "Prometheus scrape" "Target health: up"
  log "  ✓ Prometheus scraping app"
elif echo "$targets_out" | grep -q '"health":"down"'; then
  last_err=$(echo "$targets_out" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['activeTargets'][0].get('lastError','unknown'))" 2>/dev/null || echo "see health.log")
  add_fail "Prometheus scrape" "Target health: down — $last_err" \
    "Prometheus is running but cannot reach :8080/metrics. Ensure demo_up.sh completed successfully. Check: docker compose -f infra/docker-compose.yaml logs prometheus | tail -20"
  log "  ✗ Prometheus target down: $last_err"
else
  add_fail "Prometheus scrape" "Prometheus not responding" \
    "Run ./scripts/demo_up.sh. If Docker is running but Prometheus is missing: docker compose -f infra/docker-compose.yaml up -d"
  log "  ✗ Prometheus not responding"
fi

# ── CHECK 6: Recording rules ─────────────────────────────────────────────────
log "[6/9] Recording rules..."
rules_out=$(http_get "http://localhost:9090/api/v1/rules")
logq "$rules_out"

expected_rules=(
  "slo:good_rate_5m"
  "slo:good_rate_1h"
  "slo:good_rate_30m"
  "slo:good_rate_6h"
  "slo:burnrate_5m"
  "slo:burnrate_1h"
  "slo:burnrate_30m"
  "slo:burnrate_6h"
  "slo:error_budget_remaining_demo"
)
rules_missing=0
for rule in "${expected_rules[@]}"; do
  if ! echo "$rules_out" | grep -q "\"$rule\""; then
    rules_missing=$((rules_missing+1))
    log "  ✗ missing recording rule: $rule"
  fi
done

if [ "$rules_missing" -eq 0 ]; then
  add_pass "Recording rules" "All ${#expected_rules[@]} rules loaded"
  log "  ✓ all recording rules loaded"
else
  add_fail "Recording rules" "$rules_missing of ${#expected_rules[@]} rules missing" \
    "Prometheus did not load recording.yml. Check: docker compose -f infra/docker-compose.yaml logs prometheus | tail -30 — look for YAML parse errors in recording.yml"
  log "  ✗ $rules_missing recording rules missing"
fi

# ── CHECK 7: Alert rules ─────────────────────────────────────────────────────
log "[7/9] Alert rules..."
for alert in "SLOFastBurnPage" "SLOSlowBurnTicket"; do
  if echo "$rules_out" | grep -q "\"$alert\""; then
    add_pass "Alert rule: $alert" "Loaded"
    log "  ✓ $alert"
  else
    add_fail "Alert rule: $alert" "Not found in Prometheus" \
      "Check: docker compose -f infra/docker-compose.yaml logs prometheus | tail -30 — look for YAML parse errors in rules.yml"
    log "  ✗ $alert missing"
  fi
done

# ── CHECK 8: Burn rate evaluates ─────────────────────────────────────────────
log "[8/9] Burn rate query evaluates..."
burnrate_out=$(http_get "http://localhost:9090/api/v1/query?query=slo:burnrate_5m")
logq "$burnrate_out"
if echo "$burnrate_out" | grep -q '"result":\[{'; then
  val=$(echo "$burnrate_out" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); r=d['data']['result']; print(round(float(r[0]['value'][1]),4) if r else 'no-data')" \
    2>/dev/null || echo "parse-error")
  add_pass "slo:burnrate_5m evaluates" "Current value: $val"
  log "  ✓ burnrate_5m = $val"
else
  add_warn "slo:burnrate_5m evaluates" "No result yet — no traffic has run" \
    "This is normal if you have not run ./scripts/run_story.sh yet. Run it and then re-check."
  log "  ~ burnrate_5m no result (no traffic yet)"
fi

# ── CHECK 9: Grafana accessible ──────────────────────────────────────────────
log "[9/9] Grafana..."
grafana_out=$(http_get "http://localhost:3000/api/health")
logq "$grafana_out"
if echo "$grafana_out" | grep -q '"database":"ok"'; then
  add_pass "Grafana" "Accessible at http://localhost:3000 — database ok"
  log "  ✓ Grafana healthy"
elif [ -z "$grafana_out" ]; then
  add_fail "Grafana" "Not responding on :3000" \
    "Run: docker compose -f infra/docker-compose.yaml up -d grafana — wait 15 seconds then retry."
  log "  ✗ Grafana not responding"
else
  add_warn "Grafana" "Responding but health unclear: ${grafana_out:0:80}" \
    "Open http://localhost:3000 manually. If login page appears, Grafana is up. Check: docker compose -f infra/docker-compose.yaml logs grafana | tail -20"
  log "  ~ Grafana response unclear"
fi

# ── Dump Prometheus logs to log file ─────────────────────────────────────────
log ""
log "============================================================"
log "  Prometheus container logs (last 30 lines)"
log "============================================================"
prom_logs=$(docker compose -f infra/docker-compose.yaml logs prometheus --tail=30 2>/dev/null || echo "Could not fetch Prometheus logs")
logq "$prom_logs"

log ""
log "============================================================"
log "  Grafana container logs (last 20 lines)"
log "============================================================"
grafana_logs=$(docker compose -f infra/docker-compose.yaml logs grafana --tail=20 2>/dev/null || echo "Could not fetch Grafana logs")
logq "$grafana_logs"

# ── Summary ───────────────────────────────────────────────────────────────────
TOTAL=$((PASS+FAIL+WARN))
log ""
log "============================================================"
log "  SUMMARY: $PASS passed · $FAIL failed · $WARN warnings"
log "============================================================"
log ""

# =============================================================================
# HTML REPORT
# =============================================================================
cat > "$HTML_FILE" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Health Report — $DEMO_NAME</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
         background: #f5f5f5; color: #1a1a1a; padding: 32px; }
  .container { max-width: 860px; margin: 0 auto; }
  h1 { font-size: 22px; font-weight: 700; margin-bottom: 4px; }
  .meta { font-size: 13px; color: #666; margin-bottom: 24px; }
  .summary { display: flex; gap: 16px; margin-bottom: 28px; }
  .badge { padding: 12px 20px; border-radius: 8px; font-weight: 700;
           font-size: 15px; text-align: center; min-width: 100px; }
  .badge-pass { background: #d1fae5; color: #065f46; }
  .badge-fail { background: #fee2e2; color: #991b1b; }
  .badge-warn { background: #fef3c7; color: #92400e; }
  .verdict-pass { background: #d1fae5; color: #065f46; padding: 12px 16px;
                  border-radius: 8px; font-weight: 600; margin-bottom: 24px; font-size: 14px; }
  .verdict-fail { background: #fee2e2; color: #991b1b; padding: 12px 16px;
                  border-radius: 8px; font-weight: 600; margin-bottom: 24px; font-size: 14px; }
  .verdict-warn { background: #fef3c7; color: #92400e; padding: 12px 16px;
                  border-radius: 8px; font-weight: 600; margin-bottom: 24px; font-size: 14px; }
  table { width: 100%; border-collapse: collapse; background: #fff;
          border-radius: 8px; overflow: hidden;
          box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin-bottom: 28px; }
  th { background: #1a1a1a; color: #fff; padding: 11px 14px;
       text-align: left; font-size: 12px; text-transform: uppercase;
       letter-spacing: 0.05em; }
  td { padding: 11px 14px; font-size: 13px; border-bottom: 1px solid #f0f0f0;
       vertical-align: top; }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: #fafafa; }
  .status { font-weight: 700; white-space: nowrap; }
  .s-pass { color: #065f46; }
  .s-fail { color: #991b1b; }
  .s-warn { color: #92400e; }
  .fix { background: #f8faff; border-left: 3px solid #3b82f6;
         padding: 8px 10px; border-radius: 0 4px 4px 0;
         font-size: 12px; color: #1e3a5f; margin-top: 4px; line-height: 1.5; }
  .fix code { background: #e8f0fe; padding: 1px 4px; border-radius: 3px;
              font-family: "SF Mono", Menlo, Monaco, monospace; font-size: 11px; }
  .log-section { background: #1a1a1a; color: #e2e8f0; padding: 16px 20px;
                 border-radius: 8px; font-family: "SF Mono", Menlo, Monaco, monospace;
                 font-size: 11px; line-height: 1.6; margin-bottom: 24px;
                 white-space: pre-wrap; word-break: break-all; max-height: 300px;
                 overflow-y: auto; }
  .section-title { font-size: 13px; font-weight: 600; color: #444;
                   text-transform: uppercase; letter-spacing: 0.05em;
                   margin-bottom: 10px; margin-top: 24px; }
  .footer { font-size: 12px; color: #999; text-align: center; margin-top: 32px; }
</style>
</head>
<body>
<div class="container">
  <h1>Demo Health Report</h1>
  <div class="meta">$DEMO_NAME &nbsp;·&nbsp; $TIMESTAMP &nbsp;·&nbsp;
    Log file: <code>health.log</code></div>

  <div class="summary">
    <div class="badge badge-pass">✓ $PASS Passed</div>
    <div class="badge badge-fail">✗ $FAIL Failed</div>
    <div class="badge badge-warn">~ $WARN Warnings</div>
  </div>

HTMLEOF

# Verdict banner
if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
  echo '<div class="verdict-pass">✓ All checks passed. Ready to record.</div>' >> "$HTML_FILE"
elif [ "$FAIL" -eq 0 ]; then
  echo '<div class="verdict-warn">~ Passed with warnings. Review warnings below before recording.</div>' >> "$HTML_FILE"
else
  echo '<div class="verdict-fail">✗ '"$FAIL"' check(s) failed. Fix issues below before recording.</div>' >> "$HTML_FILE"
fi

# Results table
cat >> "$HTML_FILE" << HTMLEOF
  <table>
    <thead>
      <tr>
        <th style="width:110px">Status</th>
        <th style="width:220px">Check</th>
        <th>Detail / Suggested Fix</th>
      </tr>
    </thead>
    <tbody>
HTMLEOF

for entry in "${RESULTS[@]}"; do
  IFS='|' read -r status label detail fix <<< "$entry"
  case "$status" in
    PASS) css="s-pass"; icon="✓ Pass" ;;
    FAIL) css="s-fail"; icon="✗ Fail" ;;
    WARN) css="s-warn"; icon="~ Warn" ;;
  esac
  # Escape HTML
  detail_esc="${detail//&/&amp;}"
  detail_esc="${detail_esc//</&lt;}"
  detail_esc="${detail_esc//>/&gt;}"
  fix_esc="${fix//&/&amp;}"
  fix_esc="${fix_esc//</&lt;}"
  fix_esc="${fix_esc//>/&gt;}"

  echo "      <tr>" >> "$HTML_FILE"
  echo "        <td><span class=\"status $css\">$icon</span></td>" >> "$HTML_FILE"
  echo "        <td>$label</td>" >> "$HTML_FILE"
  if [ -n "$fix_esc" ]; then
    echo "        <td>$detail_esc<div class=\"fix\"><strong>Suggested fix:</strong> $fix_esc</div></td>" >> "$HTML_FILE"
  else
    echo "        <td>$detail_esc</td>" >> "$HTML_FILE"
  fi
  echo "      </tr>" >> "$HTML_FILE"
done

# Prometheus logs inline
prom_logs_esc="${prom_logs//&/&amp;}"
prom_logs_esc="${prom_logs_esc//</&lt;}"
prom_logs_esc="${prom_logs_esc//>/&gt;}"

grafana_logs_esc="${grafana_logs//&/&amp;}"
grafana_logs_esc="${grafana_logs_esc//</&lt;}"
grafana_logs_esc="${grafana_logs_esc//>/&gt;}"

cat >> "$HTML_FILE" << HTMLEOF
    </tbody>
  </table>

  <div class="section-title">Prometheus container logs (last 30 lines)</div>
  <div class="log-section">$prom_logs_esc</div>

  <div class="section-title">Grafana container logs (last 20 lines)</div>
  <div class="log-section">$grafana_logs_esc</div>

  <div class="footer">
    Full diagnostic log: <code>health.log</code> in project root &nbsp;·&nbsp;
    Share this file or health.log when reporting issues
  </div>
</div>
</body>
</html>
HTMLEOF

# ── Console final summary ──────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  RESULT: $PASS passed · $FAIL failed · $WARN warnings"
echo "============================================================"
if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
  echo "  ✓ All checks passed. Ready to record."
elif [ "$FAIL" -eq 0 ]; then
  echo "  ~ Passed with warnings. Review before recording."
else
  echo "  ✗ $FAIL check(s) failed. Fix before recording."
fi
echo ""
echo "  HTML report : $HTML_FILE"
echo "  Log file    : $LOG_FILE"
echo ""
echo "  Open report : open $HTML_FILE"
echo "============================================================"
echo ""

# Exit code reflects failures so CI/scripts can check it
[ "$FAIL" -eq 0 ]
