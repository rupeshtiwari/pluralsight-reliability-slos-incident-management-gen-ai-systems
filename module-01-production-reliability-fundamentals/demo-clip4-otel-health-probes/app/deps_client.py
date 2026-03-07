from __future__ import annotations

import time
from dataclasses import dataclass

import httpx
from opentelemetry import trace

tracer = trace.get_tracer(__name__)


@dataclass
class DepResult:
    ok: bool
    status_code: int | None
    latency_ms: int
    reason: str | None = None
    payload: dict | None = None


async def timed_get(client: httpx.AsyncClient, url: str, timeout_ms: int, span_name: str) -> DepResult:
    start = time.perf_counter()
    with tracer.start_as_current_span(span_name) as span:
        try:
            resp = await client.get(url, timeout=timeout_ms / 1000.0)
            latency_ms = int((time.perf_counter() - start) * 1000)

            span.set_attribute("http.status_code", resp.status_code)
            span.set_attribute("dep.latency_ms", latency_ms)

            if resp.status_code >= 400:
                return DepResult(False, resp.status_code, latency_ms, reason=f"http_{resp.status_code}")

            try:
                payload = resp.json()
            except Exception:
                payload = None

            return DepResult(True, resp.status_code, latency_ms, payload=payload)

        except httpx.TimeoutException:
            latency_ms = int((time.perf_counter() - start) * 1000)
            span.set_attribute("dep.latency_ms", latency_ms)
            span.set_attribute("dep.error", "timeout")
            return DepResult(False, None, latency_ms, reason="timeout")
        except Exception as e:
            latency_ms = int((time.perf_counter() - start) * 1000)
            span.set_attribute("dep.latency_ms", latency_ms)
            span.set_attribute("dep.error", str(e))
            return DepResult(False, None, latency_ms, reason="error")
