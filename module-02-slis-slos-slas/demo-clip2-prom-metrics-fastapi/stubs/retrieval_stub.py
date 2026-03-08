from __future__ import annotations

import asyncio
from fastapi import FastAPI, Query
from fastapi.responses import JSONResponse

app = FastAPI(title="Retrieval Stub")

MODE: str = "normal"  # normal | slow | empty


@app.post("/admin/mode")
def set_mode(mode: str = Query("normal")):
    global MODE
    MODE = mode
    return {"mode": MODE}


@app.get("/search")
async def search():
    if MODE == "slow":
        await asyncio.sleep(0.8)
    if MODE == "empty":
        return {"hit": False}
    return {"hit": True}
