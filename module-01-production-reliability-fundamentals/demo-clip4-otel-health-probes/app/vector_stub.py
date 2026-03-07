from __future__ import annotations

import asyncio
from typing import Literal

from fastapi import FastAPI
from fastapi.responses import JSONResponse

app = FastAPI(title="Vector DB Stub")

MODE: Literal["normal", "slow", "empty", "low_score"] = "normal"


@app.get("/health")
async def health():
    if MODE == "slow":
        await asyncio.sleep(0.4)
    return {"status": "ok"}


@app.get("/search")
async def search(query: str = ""):
    if MODE == "slow":
        await asyncio.sleep(0.4)
    if MODE == "empty":
        return {"topk_count": 0, "topk_score": 0.0, "chunks": []}
    if MODE == "low_score":
        return {"topk_count": 5, "topk_score": 0.2, "chunks": ["irrelevant"]}
    return {"topk_count": 5, "topk_score": 0.82, "chunks": ["relevant chunk A", "relevant chunk B"]}


@app.post("/admin/mode")
async def set_mode(mode: str):
    global MODE
    if mode not in ("normal", "slow", "empty", "low_score"):
        return JSONResponse({"error": "mode must be normal|slow|empty|low_score"}, status_code=400)
    MODE = mode  # type: ignore
    return {"mode": MODE}


@app.get("/admin/mode")
async def get_mode():
    return {"mode": MODE}
