#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { printf "\n[%s] %s\n" "$(date +%H:%M:%S)" "$1"; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This setup script is for macOS only." >&2
  exit 1
fi

# 1) Homebrew
if ! command -v brew >/dev/null 2>&1; then
  log "Installing Homebrew"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # shellcheck disable=SC2016
  if [[ -d "/opt/homebrew" ]]; then
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
    eval "$(/opt/homebrew/bin/brew shellenv)"
  else
    echo 'eval "$(/usr/local/bin/brew shellenv)"' >> "$HOME/.zprofile"
    eval "$(/usr/local/bin/brew shellenv)"
  fi
else
  log "Homebrew already installed"
fi

log "Updating Homebrew"
brew update

# 2) Core CLI tools
log "Installing CLI tools"
brew install git curl jq >/dev/null

# 3) Python
if ! command -v python3 >/dev/null 2>&1; then
  log "Installing Python 3.11"
  brew install python@3.11 >/dev/null
fi

# Prefer python3.11 if present
if command -v python3.11 >/dev/null 2>&1; then
  PY=python3.11
else
  PY=python3
fi

log "Python version: $($PY --version)"

# 4) Docker Desktop
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker Desktop (cask)"
  brew install --cask docker
fi

log "Starting Docker Desktop (if not running)"
open -a Docker || true

cat <<'TXT'

Next:
1) Wait until Docker Desktop shows "Docker is running".
2) Then run:
   cd module-01-production-reliability-fundamentals/demo-clip4-otel-health-probes
   ./scripts/demo_up.sh

TXT

