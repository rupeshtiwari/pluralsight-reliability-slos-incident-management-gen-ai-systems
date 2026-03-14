from __future__ import annotations
import asyncio
from fastapi import FastAPI, Query
from fastapi.responses import JSONResponse

app = FastAPI(title="Retrieval Stub")
MODE: str = "normal"

@app.post("/admin/mode")
def set_mode(mode: str = Query("normal")):
    global MODE
    MODE = mode
    return {"mode": MODE}

@app.get("/search")
async def search():
    if MODE == "slow":
        await asyncio.sleep(0.8)
    if MODE == "5xx":
        return JSONResponse(status_code=502, content={"error":"retrieval_error"})
    if MODE == "empty":
        return {"hit": False}
    return {"hit": True}
