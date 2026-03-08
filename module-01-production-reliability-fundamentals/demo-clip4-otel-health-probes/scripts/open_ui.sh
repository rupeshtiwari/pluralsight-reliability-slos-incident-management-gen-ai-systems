#!/usr/bin/env bash
set -euo pipefail

# macOS-friendly open commands
open_url() {
  local url="$1"
  if command -v open >/dev/null 2>&1; then
    open "$url"
  else
    echo "Open this URL in your browser: $url"
  fi
}

echo "[open_ui] Opening UIs..."
open_url "http://localhost:3000"   # Grafana
open_url "http://localhost:9090/targets"  # Prometheus targets
open_url "http://localhost:3200"   # Tempo (optional, Grafana Explore is better)
echo "[open_ui] Done."