from __future__ import annotations

import asyncio
from fastapi import FastAPI, Query
from fastapi.responses import JSONResponse

app = FastAPI(title="Tools Stub")

MODE: str = "normal"  # normal | 5xx | slow


@app.post("/admin/mode")
def set_mode(mode: str = Query("normal")):
    global MODE
    MODE = mode
    return {"mode": MODE}


@app.get("/call")
async def call():
    if MODE == "5xx":
        return JSONResponse(status_code=503, content={"error": "tool_down"})
    if MODE == "slow":
        await asyncio.sleep(0.6)
    return {"result": "ok"}
