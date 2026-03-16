"""
Model API Stub — simulates an LLM provider endpoint.

Modes (set via /mode endpoint or MODE env var):
  healthy    — responds in 100-300ms
  slow       — responds in 4-6s (triggers client timeout)
  throttle   — returns 429 Too Many Requests
  error      — returns 500 Internal Server Error
  flaky      — 60% healthy, 20% slow, 10% 429, 10% 500
  recovering — first N requests fail, then healthy (half-open test)
"""

import asyncio
import os
import random

from typing import Optional
from fastapi import FastAPI, Response

app = FastAPI(title="Model API Stub")
MODE = os.getenv("MODE", "healthy")
_request_count = 0
RECOVERY_AFTER = 5


@app.post("/mode/{new_mode}")
async def set_mode(new_mode: str):
    global MODE, _request_count
    MODE = new_mode
    _request_count = 0
    return {"mode": MODE}


@app.get("/mode")
async def get_mode():
    return {"mode": MODE, "request_count": _request_count}


@app.post("/generate")
async def generate(payload: Optional[dict] = None):
    global _request_count
    _request_count += 1
    prompt = (payload or {}).get("prompt", "")

    mode = MODE

    if mode == "flaky":
        r = random.random()
        if r < 0.60:
            mode = "healthy"
        elif r < 0.80:
            mode = "slow"
        elif r < 0.90:
            mode = "throttle"
        else:
            mode = "error"

    if mode == "recovering":
        mode = "error" if _request_count <= RECOVERY_AFTER else "healthy"

    if mode == "healthy":
        delay = random.uniform(0.1, 0.3)
        await asyncio.sleep(delay)
        return {
            "text": f"Model response for: {prompt[:60]}",
            "latency_ms": round(delay * 1000),
            "model": "stub-v1",
        }

    if mode == "slow":
        delay = random.uniform(4.0, 6.0)
        await asyncio.sleep(delay)
        return {
            "text": f"Slow model response for: {prompt[:60]}",
            "latency_ms": round(delay * 1000),
            "model": "stub-v1",
        }

    if mode == "throttle":
        return Response(
            content='{"error":"rate_limit_exceeded","retry_after_ms":1000}',
            status_code=429,
            media_type="application/json",
            headers={"Retry-After": "1"},
        )

    if mode == "error":
        return Response(
            content='{"error":"internal_server_error"}',
            status_code=500,
            media_type="application/json",
        )

    return {"text": "Unknown mode", "mode": mode}
