"""
GenAI Service — Alerting and Escalation Demo

Demonstrates:
  - Prometheus metrics for SLO burn rate alerting
  - Dependency health metrics for DependencyDown alerts
  - Simple /ask pipeline: vector retrieval → model inference
  - No Redis, no Toxiproxy, no tracing — purely alerting infrastructure
"""

import asyncio
import hashlib
import logging
import time
from contextlib import asynccontextmanager
from typing import Optional

import httpx
from fastapi import Body, FastAPI, HTTPException, Request
from prometheus_client import (
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)
from starlette.responses import Response

# ---------------------------------------------------------------------------
# ANSI colors
# ---------------------------------------------------------------------------
RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
BOLD = "\033[1m"
DIM = "\033[2m"
RESET = "\033[0m"

# ---------------------------------------------------------------------------
# Logging — suppress httpx noise
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-5s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("genai-service")
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
MODEL_API_URL = "http://localhost:8081"
VECTOR_DB_URL = "http://localhost:8082"
MODEL_TIMEOUT_S = 3.0
VECTOR_TIMEOUT_S = 2.0

# ---------------------------------------------------------------------------
# Log throttle — only log every Nth request and on state changes
# ---------------------------------------------------------------------------
_ask_count = 0
_last_status = None
LOG_EVERY_N = 5  # log 1 in 5 requests during steady state

# ---------------------------------------------------------------------------
# Prometheus metrics
# ---------------------------------------------------------------------------
REQUEST_TOTAL = Counter(
    "genai_requests_total",
    "Total inbound requests",
    ["endpoint", "status"],
)

REQUEST_LATENCY = Histogram(
    "genai_request_duration_seconds",
    "End-to-end request latency",
    ["endpoint"],
    buckets=[0.1, 0.25, 0.5, 1.0, 2.0, 3.0, 5.0, 8.0],
)

DEP_CALL_TOTAL = Counter(
    "genai_dependency_calls_total",
    "Calls to each dependency",
    ["dep", "result"],
)

DEP_UP = Gauge(
    "genai_dependency_up",
    "Dependency health: 1=up, 0=down",
    ["dep"],
)

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
@asynccontextmanager
async def lifespan(a: FastAPI):
    a.state.client = httpx.AsyncClient(timeout=10.0)
    DEP_UP.labels(dep="model_api").set(1)
    DEP_UP.labels(dep="vector_db").set(1)
    log.info("GenAI alerting demo service started")
    yield
    await a.state.client.aclose()

app = FastAPI(
    title="GenAI Service — Alerting and Escalation Demo",
    lifespan=lifespan,
)


# ---------------------------------------------------------------------------
# Dependency caller — no per-call logging, only metrics
# ---------------------------------------------------------------------------
async def _call_dependency(
    client: httpx.AsyncClient,
    method: str,
    url: str,
    dep_name: str,
    timeout: float,
    **kwargs,
) -> Optional[httpx.Response]:
    """Call a dependency with timeout and metric tracking."""
    start = time.monotonic()
    try:
        resp = await client.request(
            method, url, timeout=timeout, **kwargs
        )
        elapsed = time.monotonic() - start

        if resp.status_code >= 500:
            DEP_CALL_TOTAL.labels(dep=dep_name, result="error").inc()
            DEP_UP.labels(dep=dep_name).set(0)
            return None

        DEP_CALL_TOTAL.labels(dep=dep_name, result="success").inc()
        DEP_UP.labels(dep=dep_name).set(1)
        return resp

    except (httpx.TimeoutException, httpx.ConnectError) as exc:
        DEP_CALL_TOTAL.labels(dep=dep_name, result="error").inc()
        DEP_UP.labels(dep=dep_name).set(0)
        return None


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------
@app.get("/health")
async def health():
    return {"status": "ok", "service": "genai-alerting-demo"}


@app.get("/metrics")
async def metrics():
    return Response(
        content=generate_latest(),
        media_type="text/plain; version=0.0.4; charset=utf-8",
    )


@app.post("/ask")
async def ask(
    payload: Optional[dict] = Body(None),
):
    global _ask_count, _last_status

    question = (payload or {}).get("question", "What is GenAI reliability?")
    start = time.monotonic()

    client: httpx.AsyncClient = app.state.client

    # Step 1: Vector retrieval
    vector_resp = await _call_dependency(
        client, "POST", f"{VECTOR_DB_URL}/search",
        dep_name="vector_db",
        timeout=VECTOR_TIMEOUT_S,
        json={"query": question, "top_k": 3},
    )

    context = []
    if vector_resp:
        context = vector_resp.json().get("results", [])

    # Step 2: Model inference
    model_resp = await _call_dependency(
        client, "POST", f"{MODEL_API_URL}/generate",
        dep_name="model_api",
        timeout=MODEL_TIMEOUT_S,
        json={"prompt": question, "context": context},
    )

    elapsed_ms = int((time.monotonic() - start) * 1000)
    _ask_count += 1

    if model_resp:
        answer = model_resp.json().get("text", "No response")
        REQUEST_TOTAL.labels(endpoint="/ask", status="success").inc()
        REQUEST_LATENCY.labels(endpoint="/ask").observe(elapsed_ms / 1000)
        current_status = "success"

        # Log on state change or every Nth request
        state_changed = _last_status != current_status
        if state_changed or _ask_count % LOG_EVERY_N == 0:
            log.info(
                "%s%sASK  status=success  elapsed=%dms  [req %d]%s",
                GREEN, BOLD, elapsed_ms, _ask_count, RESET,
            )
        _last_status = current_status

        return {
            "answer": answer,
            "latency_ms": elapsed_ms,
            "status": "success",
        }
    else:
        REQUEST_TOTAL.labels(endpoint="/ask", status="error").inc()
        REQUEST_LATENCY.labels(endpoint="/ask").observe(elapsed_ms / 1000)
        current_status = "error"

        # Log on state change or every Nth request
        state_changed = _last_status != current_status
        if state_changed or _ask_count % LOG_EVERY_N == 0:
            log.warning(
                "%s%sASK  status=error  elapsed=%dms  [req %d]%s",
                RED, BOLD, elapsed_ms, _ask_count, RESET,
            )
        _last_status = current_status

        raise HTTPException(
            status_code=503,
            detail="Model API unavailable",
        )
