#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf "  ✓  %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  ✗  %s\n" "$1"; }

echo ""
echo "  Health Check — Mod 3 Clip 2"
echo "  ────────────────────────────────────────────"

curl -sf localhost:8000/health >/dev/null 2>&1 \
  && ok "App             :8000" || fail "App             :8000"

curl -sf localhost:8081/mode >/dev/null 2>&1 \
  && ok "Model stub      :8081" || fail "Model stub      :8081"

curl -sf localhost:8082/mode >/dev/null 2>&1 \
  && ok "Vector stub     :8082" || fail "Vector stub     :8082"

curl -sf localhost:9090/-/healthy >/dev/null 2>&1 \
  && ok "Prometheus      :9090" || fail "Prometheus      :9090"

curl -sf localhost:3000/api/health >/dev/null 2>&1 \
  && ok "Grafana         :3000" || fail "Grafana         :3000"

echo "  ────────────────────────────────────────────"
echo "  $PASS passed  $FAIL failed"
echo ""
[ "$FAIL" -eq 0 ]
