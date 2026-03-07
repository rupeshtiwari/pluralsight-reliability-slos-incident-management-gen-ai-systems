from __future__ import annotations

import asyncio
from typing import Literal

from fastapi import FastAPI
from fastapi.responses import JSONResponse

app = FastAPI(title="Model Stub")

MODE: Literal["normal", "429", "slow"] = "normal"


@app.get("/health")
async def health():
    if MODE == "slow":
        await asyncio.sleep(0.6)
    if MODE == "429":
        return JSONResponse({"status": "throttled"}, status_code=429)
    return {"status": "ok"}


@app.get("/complete")
async def complete(prompt: str = ""):
    if MODE == "slow":
        await asyncio.sleep(0.6)
    if MODE == "429":
        return JSONResponse({"error": "throttled"}, status_code=429)
    return {"completion": f"stubbed completion for '{prompt}'"}


@app.post("/admin/mode")
async def set_mode(mode: str):
    global MODE
    if mode not in ("normal", "429", "slow"):
        return JSONResponse({"error": "mode must be normal|429|slow"}, status_code=400)
    MODE = mode  # type: ignore
    return {"mode": MODE}


@app.get("/admin/mode")
async def get_mode():
    return {"mode": MODE}
