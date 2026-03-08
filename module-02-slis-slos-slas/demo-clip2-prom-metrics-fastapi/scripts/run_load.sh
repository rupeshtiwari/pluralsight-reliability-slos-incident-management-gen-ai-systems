#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-normal}"
N="${2:-10}"

for i in $(seq 1 "$N"); do
  curl -s -X POST http://localhost:8080/chat \
    -H 'content-type: application/json' \
    -d "{\"prompt\":\"hello-${i}\",\"mode\":\"${MODE}\"}" >/dev/null
  sleep 0.2
done

echo "[load] sent ${N} requests (mode=${MODE})"