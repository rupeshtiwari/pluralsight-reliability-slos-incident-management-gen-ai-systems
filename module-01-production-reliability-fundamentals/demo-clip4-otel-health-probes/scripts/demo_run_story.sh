#!/usr/bin/env bash
set -euo pipefail

log() { printf "\n[%s] %s\n" "$(date +%H:%M:%S)" "$1"; }

log "Baseline: /live"
curl -s http://localhost:8080/live | jq

log "Baseline: /ready (expect ok)"
curl -s http://localhost:8080/ready | jq

log "Baseline: deep probe (expect pass)"
curl -s -w "\nHTTP %{http_code}\n" http://localhost:8080/probe/deep | jq

log "Inject failure: Model 429"
curl -s -X POST "http://localhost:9001/admin/mode?mode=429" | jq

log "Proof 1: /live stays green"
curl -s http://localhost:8080/live | jq

log "Proof 2: /ready becomes degraded (boundary=model)"
curl -s http://localhost:8080/ready | jq

log "Proof 3: deep probe fails (503), metric increments, trace shows 429"
curl -s -w "\nHTTP %{http_code}\n" http://localhost:8080/probe/deep | jq

log "Recover: Model back to normal"
curl -s -X POST "http://localhost:9001/admin/mode?mode=normal" | jq

log "Confirm: /ready ok"
curl -s http://localhost:8080/ready | jq

log "Confirm: deep probe passes"
curl -s -w "\nHTTP %{http_code}\n" http://localhost:8080/probe/deep | jq

log "Done. In Grafana, open dashboard 'GenAI Health + Probes' and Tempo traces."
