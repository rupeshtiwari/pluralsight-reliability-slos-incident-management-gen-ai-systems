#!/usr/bin/env bash
# Scene 4 — Baseline healthy request
bash scripts/set_mode.sh model healthy
curl -s -X POST localhost:8000/ask \
  -H 'content-type: application/json' \
  -d '{"question":"What is an SLO?"}' | python3 -m json.tool
