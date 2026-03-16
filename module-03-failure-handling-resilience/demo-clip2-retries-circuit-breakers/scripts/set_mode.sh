#!/usr/bin/env bash
set -euo pipefail
DEP="${1:?dependency required: model|vector}"
MODE="${2:?mode required}"

case "$DEP" in
  model)  URL="http://localhost:8081/mode/${MODE}" ;;
  vector) URL="http://localhost:8082/mode/${MODE}" ;;
  *) echo "unknown dependency: $DEP  (use: model|vector)"; exit 1 ;;
esac

curl -s -X POST "$URL" | python3 -m json.tool
echo "[mode] ${DEP}=${MODE}"
