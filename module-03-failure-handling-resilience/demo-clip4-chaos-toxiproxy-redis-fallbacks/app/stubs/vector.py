"""
Vector DB Stub — simulates a vector search endpoint.

Modes (set via /mode endpoint or MODE env var):
  healthy    — responds in 50-150ms
  slow       — responds in 3-5s (triggers client timeout)
  throttle   — returns 429
  error      — returns 502 Bad Gateway
  flaky      — 70% healthy, 15% slow, 10% 429, 5% 502
"""

import asyncio
import os
import random

from typing import Optional
from fastapi import FastAPI, Response

app = FastAPI(title="Vector DB Stub")
MODE = os.getenv("MODE", "healthy")


@app.post("/mode/{new_mode}")
async def set_mode(new_mode: str):
    global MODE
    MODE = new_mode
    return {"mode": MODE}


@app.get("/mode")
async def get_mode():
    return {"mode": MODE}


@app.post("/search")
async def search(payload: Optional[dict] = None):
    query = (payload or {}).get("query", "")
    top_k = (payload or {}).get("top_k", 3)

    mode = MODE
    if mode == "flaky":
        r = random.random()
        if r < 0.70:
            mode = "healthy"
        elif r < 0.85:
            mode = "slow"
        elif r < 0.95:
            mode = "throttle"
        else:
            mode = "error"

    if mode == "healthy":
        delay = random.uniform(0.05, 0.15)
        await asyncio.sleep(delay)
        return {
            "results": [
                {
                    "id": f"doc-{i}",
                    "score": round(0.95 - i * 0.05, 2),
                    "text": f"Chunk {i} for: {query[:40]}",
                }
                for i in range(top_k)
            ],
            "latency_ms": round(delay * 1000),
        }

    if mode == "slow":
        delay = random.uniform(3.0, 5.0)
        await asyncio.sleep(delay)
        return {"results": [], "latency_ms": round(delay * 1000)}

    if mode == "throttle":
        return Response(
            content='{"error":"too_many_requests"}',
            status_code=429,
            media_type="application/json",
        )

    if mode == "error":
        return Response(
            content='{"error":"bad_gateway"}',
            status_code=502,
            media_type="application/json",
        )

    return {"results": []}
