#!/usr/bin/env bash
# Scene 6 — Confirm full recovery
curl -s localhost:8000/breaker/status | python3 -m json.tool
