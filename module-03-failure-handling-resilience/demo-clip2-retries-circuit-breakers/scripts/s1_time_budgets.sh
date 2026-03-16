#!/usr/bin/env bash
# Scene 1 — Time Budgets
grep "MODEL_TIMEOUT_S\|VECTOR_TIMEOUT_S" app/main.py | grep "^MODEL\|^VECTOR"
