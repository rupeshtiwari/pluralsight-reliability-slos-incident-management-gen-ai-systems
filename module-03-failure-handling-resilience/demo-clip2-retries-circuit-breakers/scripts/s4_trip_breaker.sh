#!/usr/bin/env bash
# Scene 4 — Drive breaker OPEN with 500 errors
bash scripts/set_mode.sh model error
for i in 1 2 3 4 5 6 7; do
  echo "--- request $i ---"
  curl -s -X POST localhost:8000/ask \
    -H 'content-type: application/json' \
    -d '{"question":"trip the breaker"}' | python3 -m json.tool
  sleep 0.3
done
