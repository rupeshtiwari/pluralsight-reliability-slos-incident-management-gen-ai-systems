#!/usr/bin/env bash
set -uo pipefail

DURATION="${1:?usage: run_load.sh <seconds>}"
END=$((SECONDS + DURATION))
COUNT=0

echo "=========================================================="
echo " run_load.sh  — sending traffic for ${DURATION}s"
echo " $(date +%H:%M:%S)"
echo "=========================================================="
echo ""

while [ $SECONDS -lt $END ]; do
  COUNT=$((COUNT + 1))
  RESULT=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" \
    -X POST localhost:8000/ask \
    -H 'content-type: application/json' \
    -d '{"question":"What is an SLO?"}')
  STATUS=$(echo "$RESULT" | awk '{print $1}')
  TIME=$(echo "$RESULT" | awk '{print $2}')
  printf "  req=%-4d  status=%s  time=%ss\n" "$COUNT" "$STATUS" "$TIME"
  sleep 0.5
done

echo ""
echo "=========================================================="
echo " DONE — ${COUNT} requests sent"
echo " $(date +%H:%M:%S)"
echo "=========================================================="
