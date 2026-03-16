#!/usr/bin/env bash
# Usage:
#   bash scripts/set_toxic.sh model latency 3000
#   bash scripts/set_toxic.sh vector bandwidth 10
#   bash scripts/set_toxic.sh model reset_peer 0
#   bash scripts/set_toxic.sh model latency 1500 (for idempotency scene)
set -euo pipefail

DEP="${1:?dependency required: model|vector}"
TYPE="${2:?type required: latency|bandwidth|reset_peer}"
VALUE="${3:-1000}"

case "$DEP" in
  model)  PROXY="model-api" ;;
  vector) PROXY="vector-db" ;;
  *) echo "unknown dep: $DEP (use model or vector)"; exit 1 ;;
esac

TOXI_URL="http://localhost:8474/proxies/${PROXY}/toxics"

case "$TYPE" in
  latency)
    PAYLOAD="{\"name\":\"latency\",\"type\":\"latency\",\"stream\":\"downstream\",\"toxicity\":1.0,\"attributes\":{\"latency\":${VALUE},\"jitter\":0}}"
    ;;
  bandwidth)
    PAYLOAD="{\"name\":\"bandwidth\",\"type\":\"bandwidth\",\"stream\":\"downstream\",\"toxicity\":1.0,\"attributes\":{\"rate\":${VALUE}}}"
    ;;
  reset_peer)
    PAYLOAD="{\"name\":\"reset\",\"type\":\"reset_peer\",\"stream\":\"downstream\",\"toxicity\":1.0,\"attributes\":{\"timeout\":${VALUE}}}"
    ;;
  *)
    echo "unknown type: $TYPE (use latency, bandwidth, or reset_peer)"
    exit 1
    ;;
esac

echo "[toxic] adding ${TYPE} to ${PROXY} (value=${VALUE})"
curl -s -X POST "$TOXI_URL" \
  -H 'content-type: application/json' \
  -d "$PAYLOAD" | python3 -m json.tool
