#!/usr/bin/env bash
# Scene 2 — Show retry budget status
curl -s localhost:8000/breaker/status | python3 -m json.tool
