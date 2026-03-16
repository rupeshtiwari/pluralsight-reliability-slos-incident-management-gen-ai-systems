#!/usr/bin/env bash
# Usage:
#   bash scripts/clear_toxics.sh model
#   bash scripts/clear_toxics.sh vector
#   bash scripts/clear_toxics.sh all
set -euo pipefail

DEP="${1:?dep required: model|vector|all}"

clear_proxy() {
  local proxy="$1"
  local toxics
  toxics=$(curl -sf "http://localhost:8474/proxies/${proxy}/toxics" 2>/dev/null || echo "[]")
  echo "$toxics" | python3 -c "
import sys, json
toxics = json.load(sys.stdin)
names = [t['name'] for t in toxics]
print(f'  {len(names)} toxics found: {names}')
" 2>/dev/null || true

  # Remove each toxic by name
  local names
  names=$(curl -sf "http://localhost:8474/proxies/${proxy}/toxics" 2>/dev/null | \
    python3 -c "import sys,json; [print(t['name']) for t in json.load(sys.stdin)]" 2>/dev/null || true)

  if [ -z "$names" ]; then
    echo "  [clear] ${proxy} — no toxics active"
    return
  fi

  echo "$names" | while read -r name; do
    curl -sf -X DELETE "http://localhost:8474/proxies/${proxy}/toxics/${name}" > /dev/null && \
      echo "  [clear] ${proxy} toxic '${name}' removed"
  done
}

case "$DEP" in
  model) clear_proxy "model-api" ;;
  vector) clear_proxy "vector-db" ;;
  all)
    clear_proxy "model-api"
    clear_proxy "vector-db"
    echo "[clear] all toxics removed"
    ;;
  *) echo "unknown dep: $DEP (use model, vector, or all)"; exit 1 ;;
esac

echo ""
echo "Current proxy state:"
curl -s localhost:8474/proxies | python3 -m json.tool 2>/dev/null | grep -A2 '"name"' || true
