#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-normal}"
DURATION_SEC="${2:-30}"
SLEEP_SEC="${3:-0.05}"

end=$(( $(date +%s) + DURATION_SEC ))
i=0
while [ "$(date +%s)" -lt "$end" ]; do
  i=$((i+1))
  curl -s -X POST http://localhost:8080/chat     -H 'content-type: application/json'     -d "{"prompt":"hello-${i}","mode":"${MODE}"}" >/dev/null
  sleep "$SLEEP_SEC"
done
echo "[load] duration=${DURATION_SEC}s mode=${MODE} requests=${i}"
