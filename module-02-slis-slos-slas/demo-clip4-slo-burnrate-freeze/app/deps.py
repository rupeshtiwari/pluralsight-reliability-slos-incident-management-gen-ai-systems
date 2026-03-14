from __future__ import annotations
import time
from dataclasses import dataclass
from typing import Optional, Dict, Any
import httpx

@dataclass
class DepResult:
    ok: bool
    status_code: int
    latency_s: float
    payload: Optional[Dict[str, Any]]
    error_type: Optional[str]

async def call_json(url: str, timeout_ms: int) -> DepResult:
    t0 = time.perf_counter()
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(url, timeout=timeout_ms / 1000)
        lat = time.perf_counter() - t0

        payload: Optional[Dict[str, Any]] = None
        try:
            payload = r.json()
        except Exception:
            payload = None

        if 200 <= r.status_code < 300:
            return DepResult(True, r.status_code, lat, payload, None)
        if r.status_code == 429:
            return DepResult(False, r.status_code, lat, payload, "429")
        if r.status_code >= 500:
            return DepResult(False, r.status_code, lat, payload, "5xx")
        return DepResult(False, r.status_code, lat, payload, "other")
    except httpx.TimeoutException:
        lat = time.perf_counter() - t0
        return DepResult(False, 0, lat, None, "timeout")
    except Exception:
        lat = time.perf_counter() - t0
        return DepResult(False, 0, lat, None, "other")
