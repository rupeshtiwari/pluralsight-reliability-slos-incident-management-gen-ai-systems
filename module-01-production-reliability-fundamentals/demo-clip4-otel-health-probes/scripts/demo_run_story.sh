#!/usr/bin/env bash
set -euo pipefail

log() { printf "\n[%s] %s\n" "$(date +%H:%M:%S)" "$1"; }

curl_json () {
  # Prints JSON pretty if jq exists, otherwise raw
  local method="$1"; shift
  local url="$1"; shift
  if command -v jq >/dev/null 2>&1; then
    curl -s -X "$method" "$url" "$@" | jq .
  else
    curl -s -X "$method" "$url" "$@"
  fi
}

curl_status () {
  # Prints only HTTP status code
  curl -s -o /dev/null -w "%{http_code}" "$1"
}

log "Baseline: /live"
curl_json GET "http://localhost:8080/live"

log "Baseline: /ready (expect ok)"
curl_json GET "http://localhost:8080/ready"

log "Baseline: deep probe (expect pass)"
curl_json GET "http://localhost:8080/probe/deep"
echo "HTTP $(curl_status http://localhost:8080/probe/deep)"

log "Inject failure: Model 429"
curl_json POST "http://localhost:9001/admin/mode?mode=429"

log "Proof 1: /live stays green"
curl_json GET "http://localhost:8080/live"

log "Proof 2: /ready becomes degraded (boundary=model)"
curl_json GET "http://localhost:8080/ready"

log "Proof 3: deep probe fails (expect HTTP 503)"
curl_json GET "http://localhost:8080/probe/deep"
echo "HTTP $(curl_status http://localhost:8080/probe/deep)"

log "Recover: Model back to normal"
curl_json POST "http://localhost:9001/admin/mode?mode=normal"

log "Confirm: /ready ok"
curl_json GET "http://localhost:8080/ready"

log "Confirm: deep probe passes"
curl_json GET "http://localhost:8080/probe/deep"
echo "HTTP $(curl_status http://localhost:8080/probe/deep)"

log "Next proof: Grafana -> Explore -> Tempo, open latest /probe/deep trace"
log "Metric proof: Prometheus query probe_result_total"