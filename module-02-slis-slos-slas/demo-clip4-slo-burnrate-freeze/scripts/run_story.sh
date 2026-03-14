#!/usr/bin/env bash
set -euo pipefail
log(){ printf "\n[%s] %s\n" "$(date +%H:%M:%S)" "$1"; }

log "Baseline: good traffic so burn rate is low"
./scripts/set_mode.sh model normal
./scripts/set_mode.sh retrieval normal
./scripts/set_mode.sh tools normal
./scripts/run_load.sh normal 20 0.05

log "Inject model 429: fast burn page and freeze trigger"
./scripts/set_mode.sh model 429
./scripts/run_load.sh normal 75 0.02

log "Recover: back to normal"
./scripts/set_mode.sh model normal
./scripts/run_load.sh normal 15 0.05

log "Done: open Grafana dashboard SLO Compliance GenAI API"
