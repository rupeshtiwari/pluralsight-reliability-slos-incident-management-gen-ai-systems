from __future__ import annotations

from typing import Literal

import httpx
from fastapi import FastAPI
from fastapi.responses import JSONResponse, PlainTextResponse
from prometheus_client import (
    Counter,
    Gauge,
    Histogram,
    generate_latest,
    CONTENT_TYPE_LATEST,
)

from settings import SETTINGS
from otel import init_tracing
from deps_client import timed_get

# Create the app first
app = FastAPI(title="GenAI Health + Synthetic Probe Demo")

# IMPORTANT: Instrument immediately after app creation.
# Do NOT do this inside startup events, or FastAPI will reject adding middleware later.
init_tracing(app, SETTINGS.service_name, SETTINGS.otlp_endpoint)

# ---------------- Metrics (Prometheus) ----------------
probe_result_total = Counter(
    "probe_result_total",
    "Synthetic probe results",
    labelnames=["route", "status", "boundary", "reason"],
)
ready_state = Gauge(
    "ready_state",
    "Readiness state: 1=ok, 0=degraded, -1=down",
)

dep_latency_ms = Histogram(
    "dependency_latency_ms",
    "Dependency latency in ms",
    labelnames=["boundary"],
    buckets=(25, 50, 100, 150, 200, 300, 400, 600, 1000, 2000),
)


def state_to_gauge(status: str) -> int:
    if status == "ok":
        return 1
    if status == "degraded":
        return 0
    return -1


@app.get("/metrics")
def metrics():
    return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/live")
async def live():
    # Intentionally dumb: no dependency calls.
    return {"status": "alive"}


async def check_ready() -> dict:
    """Cheap readiness checks with budgets.

    Returns a payload with:
    - status: ok|degraded|down
    - failed_boundary
    - reason
    - latency_ms per boundary
    - budgets_ms
    """
    async with httpx.AsyncClient() as client:
        model = await timed_get(
            client,
            f"{SETTINGS.model_base_url}/health",
            timeout_ms=SETTINGS.ready_model_budget_ms,
            span_name="ready.model",
        )
        vector = await timed_get(
            client,
            f"{SETTINGS.vector_base_url}/health",
            timeout_ms=SETTINGS.ready_vector_budget_ms,
            span_name="ready.vector",
        )

    dep_latency_ms.labels(boundary="model").observe(model.latency_ms)
    dep_latency_ms.labels(boundary="vector").observe(vector.latency_ms)

    budgets = {
        "model": SETTINGS.ready_model_budget_ms,
        "vector": SETTINGS.ready_vector_budget_ms,
    }
    lats = {
        "model": model.latency_ms,
        "vector": vector.latency_ms,
    }

    # Decision logic (advanced):
    # - If either dependency is hard-down (timeout/error), readiness is degraded.
    # - We keep "down" reserved for the app itself not serving (not simulated here).
    status = "ok"
    failed_boundary = None
    reason = None

    if not model.ok:
        status = "degraded"
        failed_boundary = "model"
        reason = model.reason
    elif not vector.ok:
        status = "degraded"
        failed_boundary = "vector"
        reason = vector.reason

    payload = {
        "status": status,
        "failed_boundary": failed_boundary,
        "reason": reason,
        "latency_ms": lats,
        "budgets_ms": budgets,
    }
    return payload


@app.get("/ready")
async def ready():
    payload = await check_ready()
    ready_state.set(state_to_gauge(payload["status"]))
    return JSONResponse(payload)


async def deep_probe() -> dict:
    """Deep synthetic probe.

    Verifies:
    - Retrieval non-empty (topk_count)
    - Retrieval relevance (topk_score)
    - Dependency behavior bounded (budgets)
    """
    async with httpx.AsyncClient() as client:
        # 1) Retrieval
        retrieval = await timed_get(
            client,
            f"{SETTINGS.vector_base_url}/search?query=known_probe",
            timeout_ms=SETTINGS.deep_vector_budget_ms,
            span_name="probe.vector.search",
        )

        # 2) Model
        model = await timed_get(
            client,
            f"{SETTINGS.model_base_url}/complete?prompt=known_probe",
            timeout_ms=SETTINGS.deep_model_budget_ms,
            span_name="probe.model.call",
        )

    dep_latency_ms.labels(boundary="model").observe(model.latency_ms)
    dep_latency_ms.labels(boundary="vector").observe(retrieval.latency_ms)

    # Default: pass
    status: Literal["pass", "fail"] = "pass"
    boundary = "none"
    reason = "none"

    # Dependency bounded behavior
    if not retrieval.ok:
        status = "fail"
        boundary = "vector"
        reason = retrieval.reason or "unknown"
    elif not model.ok:
        status = "fail"
        boundary = "model"
        reason = model.reason or "unknown"
    else:
        # Quality gates
        payload = retrieval.payload or {}
        topk_count = int(payload.get("topk_count", 0))
        topk_score = float(payload.get("topk_score", 0.0))

        if topk_count < SETTINGS.min_topk_count:
            status = "fail"
            boundary = "vector"
            reason = "empty_topk"
        elif topk_score < SETTINGS.min_topk_score:
            status = "fail"
            boundary = "vector"
            reason = "low_score"

    probe_result_total.labels(
        route="/probe/deep", status=status, boundary=boundary, reason=reason
    ).inc()

    return {
        "status": status,
        "boundary": boundary,
        "reason": reason,
        "vector_latency_ms": retrieval.latency_ms,
        "model_latency_ms": model.latency_ms,
        "budgets_ms": {
            "vector": SETTINGS.deep_vector_budget_ms,
            "model": SETTINGS.deep_model_budget_ms,
        },
    }


@app.get("/probe/deep")
async def probe_deep():
    payload = await deep_probe()
    # Service-level decision: deep probe failure = degraded, not down.
    http_status = 200 if payload["status"] == "pass" else 503
    return JSONResponse(payload, status_code=http_status)


@app.get("/")
async def root():
    return {
        "service": SETTINGS.service_name,
        "routes": ["/live", "/ready", "/probe/deep", "/metrics"],
        "grafana": "http://localhost:3000",
        "prometheus": "http://localhost:9090",
        "tempo": "http://localhost:3200",
    }
