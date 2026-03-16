#!/usr/bin/env bash
# Scene 5 — Half-open recovery
bash scripts/set_mode.sh model recovering
echo "Waiting 12s for recovery timeout..."
sleep 12
for i in 1 2 3 4 5; do
  echo "--- probe $i ---"
  curl -s -X POST localhost:8000/ask \
    -H 'content-type: application/json' \
    -d '{"question":"probe"}' | python3 -m json.tool
  sleep 0.8
done
