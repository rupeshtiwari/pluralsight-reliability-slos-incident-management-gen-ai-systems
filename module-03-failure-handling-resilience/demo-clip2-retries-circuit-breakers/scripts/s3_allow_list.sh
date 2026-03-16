#!/usr/bin/env bash
# Scene 3 — Safe failure class allow-list
grep -A8 "RETRYABLE_STATUS_CODES\|def _is_retryable" app/main.py | head -14
