#!/usr/bin/env bash
# Scene 2 — Exponential backoff with jitter
bash scripts/set_mode.sh model throttle
curl -s -X POST localhost:8000/ask \
  -H 'content-type: application/json' \
  -d '{"question":"backoff test"}' | python3 -m json.tool
