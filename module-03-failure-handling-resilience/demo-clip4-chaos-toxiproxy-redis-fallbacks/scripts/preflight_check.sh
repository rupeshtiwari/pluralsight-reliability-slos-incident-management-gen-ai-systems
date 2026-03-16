#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf "  [PASS]  %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  [FAIL]  %s\n" "$1"; }

echo ""
echo "  Pre-flight Check — Mod 3 Clip 4"
echo "  --------------------------------------------------------"

# 1 Python
python3 --version >/dev/null 2>&1 && ok "Python $(python3 --version 2>&1)" || fail "Python not found"

# 2 Docker
docker info >/dev/null 2>&1 && ok "Docker running" || fail "Docker not running"

# 3 Venv + deps
if [ -f ".venv/bin/python" ]; then
  .venv/bin/python -c "import fastapi, uvicorn, httpx, redis, opentelemetry" 2>/dev/null \
    && ok "All Python packages importable" || fail "Missing packages — run demo_up.sh"
else
  fail "No .venv found — run demo_up.sh"
fi

# 4 App health
H=$(curl -sf --max-time 4 localhost:8000/health 2>/dev/null)
if echo "$H" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['status']=='ok'" 2>/dev/null; then
  REDIS=$(echo "$H" | python3 -c "import sys,json; print(json.load(sys.stdin)['redis'])")
  ok "App :8000  redis=${REDIS}"
else
  fail "App :8000 not healthy"
fi

# 5 Model stub
curl -sf --max-time 3 localhost:8081/mode >/dev/null 2>&1 \
  && ok "Model stub :8081" || fail "Model stub :8081 not responding"

# 6 Vector stub
curl -sf --max-time 3 localhost:8082/mode >/dev/null 2>&1 \
  && ok "Vector stub :8082" || fail "Vector stub :8082 not responding"

# 7 Toxiproxy
PROXIES=$(curl -sf --max-time 4 localhost:8474/proxies 2>/dev/null)
if echo "$PROXIES" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'model-api' in d and 'vector-db' in d" 2>/dev/null; then
  ok "Toxiproxy :8474  proxies=model-api,vector-db"
else
  fail "Toxiproxy :8474 not ready or proxies missing"
fi

# 8 Redis via app
curl -sf --max-time 4 localhost:8000/cache/status >/dev/null 2>&1 \
  && ok "Redis reachable via app :6379" || fail "Redis not reachable"

# 9 Toxiproxy routing — model via proxy
MODEL_RESP=$(curl -sf --max-time 5 -X POST localhost:8091/generate \
  -H 'content-type: application/json' \
  -d '{"prompt":"preflight"}' 2>/dev/null)
echo "$MODEL_RESP" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null \
  && ok "Toxiproxy model-api proxy :8091 routing" || fail "Toxiproxy model-api proxy NOT routing to stub"

# 10 Toxiproxy routing — vector via proxy
VEC_RESP=$(curl -sf --max-time 5 -X POST localhost:8092/search \
  -H 'content-type: application/json' \
  -d '{"query":"preflight","top_k":1}' 2>/dev/null)
echo "$VEC_RESP" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null \
  && ok "Toxiproxy vector-db proxy :8092 routing" || fail "Toxiproxy vector-db proxy NOT routing to stub"

# 11 End-to-end ask
ASK=$(curl -sf --max-time 10 -X POST localhost:8000/ask \
  -H 'content-type: application/json' \
  -d '{"question":"What is an SLO?"}' 2>/dev/null)
if echo "$ASK" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'answer' in d" 2>/dev/null; then
  DEG=$(echo "$ASK" | python3 -c "import sys,json; print(json.load(sys.stdin).get('degraded',False))")
  ok "End-to-end /ask  degraded=${DEG}"
else
  fail "POST /ask failed"
fi

# 12 Cache warmed
CACHE=$(curl -sf localhost:8000/cache/status 2>/dev/null)
KEYS=$(echo "$CACHE" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['cache_keys']))" 2>/dev/null || echo "0")
[ "$KEYS" -gt "0" ] && ok "Redis answer cache has ${KEYS} key(s) — ready for fallback demo" \
  || fail "Redis cache is empty — fallback demo will not work. Re-run demo_up.sh"

# 13 Prometheus
curl -sf --max-time 5 localhost:9090/-/healthy >/dev/null 2>&1 \
  && ok "Prometheus :9090" || fail "Prometheus :9090 not healthy"

# 14 Grafana
curl -sf --max-time 5 localhost:3000/api/health 2>/dev/null | grep -q "ok" \
  && ok "Grafana :3000" || fail "Grafana :3000 not healthy"

# 15 Tempo
curl -sf --max-time 5 localhost:3200/ready 2>/dev/null | grep -q "ready" \
  && ok "Tempo :3200" || fail "Tempo :3200 not ready"

echo "  --------------------------------------------------------"
echo "  $PASS passed  $FAIL failed"
echo ""

if [ "$FAIL" -eq 0 ]; then
  echo "  ALL CHECKS PASSED — READY TO RECORD"
else
  echo "  $FAIL CHECK(S) FAILED — FIX BEFORE RECORDING"
fi
echo ""
exit $FAIL
