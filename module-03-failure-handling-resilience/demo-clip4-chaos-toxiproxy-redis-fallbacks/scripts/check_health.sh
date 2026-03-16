#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf "  [OK]    %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  [FAIL]  %s\n" "$1"; }

echo ""
echo "  Health Check — Mod 3 Clip 4"
echo "  ----------------------------------------"

curl -sf localhost:8000/health >/dev/null 2>&1 && ok "App         :8000" || fail "App         :8000"
curl -sf localhost:8081/mode  >/dev/null 2>&1 && ok "Model stub  :8081" || fail "Model stub  :8081"
curl -sf localhost:8082/mode  >/dev/null 2>&1 && ok "Vector stub :8082" || fail "Vector stub :8082"
curl -sf localhost:8474/proxies >/dev/null 2>&1 && ok "Toxiproxy   :8474" || fail "Toxiproxy   :8474"
docker exec clip4-redis redis-cli ping 2>/dev/null | grep -q PONG && ok "Redis       :6379" || fail "Redis       :6379"
curl -sf localhost:9090/-/healthy >/dev/null 2>&1 && ok "Prometheus  :9090" || fail "Prometheus  :9090"
curl -sf localhost:3200/ready 2>/dev/null | grep -q "ready" && ok "Tempo       :3200" || fail "Tempo       :3200"
curl -sf localhost:3000/api/health 2>/dev/null | grep -q "ok" && ok "Grafana     :3000" || fail "Grafana     :3000"

echo "  ----------------------------------------"
echo "  $PASS passed  $FAIL failed"
echo ""
[ "$FAIL" -eq 0 ]
