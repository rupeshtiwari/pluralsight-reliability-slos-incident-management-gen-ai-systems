#!/usr/bin/env bash
# Print a visual divider in the webhook log between demo scenes
LABEL="${1:?usage: scene_divider.sh <scene-name>}"
curl -s -X POST "localhost:5001/divider/${LABEL}" > /dev/null 2>&1
echo "[divider] ${LABEL}"
