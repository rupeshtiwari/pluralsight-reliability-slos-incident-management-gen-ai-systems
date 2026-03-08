#!/usr/bin/env bash
set -euo pipefail

log() { printf "\n[%s] %s\n" "$(date +%H:%M:%S)" "$1"; }

log "Baseline (normal) -> build latency + cost series"
./scripts/set_mode.sh retrieval normal >/dev/null
./scripts/set_mode.sh model normal >/dev/null
./scripts/set_mode.sh tools normal >/dev/null
./scripts/run_load.sh normal 20

log "Retrieval slow -> push end-to-end P95 up"
./scripts/set_mode.sh retrieval slow >/dev/null
./scripts/run_load.sh normal 20
./scripts/set_mode.sh retrieval normal >/dev/null

log "Model 429 -> create labeled error counters"
./scripts/set_mode.sh model 429 >/dev/null
./scripts/run_load.sh normal 20 || true
./scripts/set_mode.sh model normal >/dev/null
./scripts/run_load.sh normal 10

log "Tool fan-out -> expensive 'success' (cost per request rises)"
./scripts/run_load.sh tool_fanout 20

log "Done. Open Grafana dashboard: GenAI SLIs (Latency, Errors, Cost)"