from __future__ import annotations
import asyncio
from fastapi import FastAPI, Query
from fastapi.responses import JSONResponse

app = FastAPI(title="Model Stub")
MODE: str = "normal"

@app.post("/admin/mode")
def set_mode(mode: str = Query("normal")):
    global MODE
    MODE = mode
    return {"mode": MODE}

@app.get("/complete")
async def complete():
    if MODE == "429":
        return JSONResponse(status_code=429, content={"error":"throttled"})
    if MODE == "slow":
        await asyncio.sleep(0.6)
    return {"text":"ok"}
