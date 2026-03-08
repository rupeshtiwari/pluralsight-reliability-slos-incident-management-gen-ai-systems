#!/usr/bin/env bash
set -euo pipefail

DEP="${1:?dependency required: model|retrieval|tools}"
MODE="${2:?mode required}"

case "$DEP" in
  model)     URL="http://localhost:9001/admin/mode?mode=${MODE}" ;;
  retrieval) URL="http://localhost:9002/admin/mode?mode=${MODE}" ;;
  tools)     URL="http://localhost:9003/admin/mode?mode=${MODE}" ;;
  *) echo "unknown dependency: $DEP"; exit 1 ;;
esac

curl -s -X POST "$URL"
echo