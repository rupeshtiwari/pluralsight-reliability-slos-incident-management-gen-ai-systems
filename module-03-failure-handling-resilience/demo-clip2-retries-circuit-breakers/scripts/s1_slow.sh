#!/usr/bin/env bash
# Scene 1 — Fire timeout
bash scripts/set_mode.sh model slow
curl -s -X POST localhost:8000/ask \
  -H 'content-type: application/json' \
  -d '{"question":"budget test"}' | python3 -m json.tool
