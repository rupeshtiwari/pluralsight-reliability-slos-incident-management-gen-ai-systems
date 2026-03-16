#!/usr/bin/env bash
# Scene 4 — Show both breaker states (bulkhead proof)
curl -s localhost:8000/breaker/status | python3 -m json.tool
