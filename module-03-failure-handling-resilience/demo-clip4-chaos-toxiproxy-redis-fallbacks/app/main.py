"""
GenAI Service — Chaos Testing with Toxiproxy, Redis, and Fallbacks

Demonstrates:
  - Redis answer cache: serve cached response when retrieval or model fails
  - Degraded mode: degraded=true flag when fallback activates
  - Idempotency keys: tool call executes once, retry returns stored result
  - In-progress state: Redis key set before tool runs, updated after
  - OpenTelemetry traces: every span instrumented for Tempo
  - Routes via Toxiproxy: chaos is injected at the network layer
"""

import asyncio
import hashlib
import json
import logging
import random
import time
from contextlib import asynccontextmanager
from typing import Any, Optional

import httpx
import redis.asyncio as aioredis
from fastapi import Body, FastAPI, Header, HTTPException, Request
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import SERVICE_NAME, Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import SpanKind, StatusCode
from prometheus_client import Counter, Gauge, Histogram, generate_latest
from starlette.responses import Response

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-5s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("genai-service")

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Routes via Toxiproxy — chaos is injected here
MODEL_API_URL = "http://localhost:8091"    # Toxiproxy → model stub :8081
VECTOR_DB_URL = "http://localhost:8092"    # Toxiproxy → vector stub :8082
REDIS_URL = "redis://localhost:6379"

MODEL_TIMEOUT_S = 3.0
VECTOR_TIMEOUT_S = 2.0

CACHE_TTL_S = 300        # 5 minutes — answer cache
IDEMPOTENCY_TTL_S = 600  # 10 minutes — idempotency keys

RETRYABLE_STATUS_CODES = {429, 500, 502, 503, 504}

# ---------------------------------------------------------------------------
# OpenTelemetry setup
# ---------------------------------------------------------------------------
resource = Resource(attributes={SERVICE_NAME: "genai-chaos-service"})
tracer_provider = TracerProvider(resource=resource)

otlp_exporter = OTLPSpanExporter(
    endpoint="http://localhost:4317",
    insecure=True,
)
tracer_provider.add_span_processor(BatchSpanProcessor(otlp_exporter))
trace.set_tracer_provider(tracer_provider)
tracer = trace.get_tracer("genai-chaos-service")

# ---------------------------------------------------------------------------
# Prometheus metrics
# ---------------------------------------------------------------------------
REQUEST_TOTAL = Counter(
    "genai_requests_total",
    "Total inbound requests",
    ["endpoint"],
)
REQUEST_LATENCY = Histogram(
    "genai_request_duration_seconds",
    "End-to-end request latency",
    ["endpoint"],
    buckets=[0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 3.0, 4.0, 5.0, 8.0],
)
CACHE_HITS = Counter(
    "genai_cache_hits_total",
    "Redis cache hits (fallback activations)",
    ["dependency"],
)
CACHE_MISSES = Counter(
    "genai_cache_misses_total",
    "Redis cache misses",
    ["dependency"],
)
DEGRADED_RESPONSES = Counter(
    "genai_degraded_responses_total",
    "Responses served in degraded mode",
    ["reason"],
)
IDEMPOTENCY_HITS = Counter(
    "genai_idempotency_hits_total",
    "Idempotency key cache hits (duplicate requests absorbed)",
)
IDEMPOTENCY_IN_PROGRESS = Gauge(
    "genai_idempotency_in_progress",
    "Tool calls currently in-progress",
)
DEP_CALL_TOTAL = Counter(
    "genai_dependency_calls_total",
    "Dependency call outcomes",
    ["dependency", "result"],
)
DEP_LATENCY = Histogram(
    "genai_dependency_duration_seconds",
    "Per-dependency call latency",
    ["dependency"],
    buckets=[0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 3.0, 5.0],
)
SLO_AVAILABILITY = Gauge(
    "genai_slo_availability_ratio",
    "Rolling availability ratio (1.0 = 100%)",
)

# ---------------------------------------------------------------------------
# Cache helpers
# ---------------------------------------------------------------------------
def _cache_key(question: str) -> str:
    h = hashlib.sha256(question.lower().strip().encode()).hexdigest()[:16]
    return f"cache:{h}"


def _idem_key(key: str) -> str:
    return f"idem:{key}"


# ---------------------------------------------------------------------------
# Resilient HTTP call with timeout and trace span
# ---------------------------------------------------------------------------
async def _call_dependency(
    client: httpx.AsyncClient,
    method: str,
    url: str,
    dep_name: str,
    timeout: float,
    **kwargs: Any,
) -> Optional[httpx.Response]:
    """Call a dependency through Toxiproxy. Returns None on failure."""
    start = time.monotonic()
    with tracer.start_as_current_span(
        f"{dep_name}.call",
        kind=SpanKind.CLIENT,
    ) as span:
        span.set_attribute("dep.name", dep_name)
        span.set_attribute("dep.url", url)
        try:
            resp = await client.request(method, url, timeout=timeout, **kwargs)
            resp.raise_for_status()
            elapsed = time.monotonic() - start
            DEP_LATENCY.labels(dependency=dep_name).observe(elapsed)
            DEP_CALL_TOTAL.labels(dependency=dep_name, result="success").inc()
            span.set_attribute("dep.status", resp.status_code)
            span.set_status(StatusCode.OK)
            log.info("DEP  %s  status=%d  elapsed=%.2fs  OK", dep_name, resp.status_code, elapsed)
            return resp
        except httpx.TimeoutException:
            elapsed = time.monotonic() - start
            DEP_LATENCY.labels(dependency=dep_name).observe(elapsed)
            DEP_CALL_TOTAL.labels(dependency=dep_name, result="timeout").inc()
            span.set_attribute("dep.error", "timeout")
            span.set_status(StatusCode.ERROR, "timeout")
            log.warning("DEP  %s  timeout after %.2fs", dep_name, elapsed)
            return None
        except httpx.HTTPStatusError as exc:
            elapsed = time.monotonic() - start
            DEP_LATENCY.labels(dependency=dep_name).observe(elapsed)
            DEP_CALL_TOTAL.labels(dependency=dep_name, result="error").inc()
            span.set_attribute("dep.status", exc.response.status_code)
            span.set_status(StatusCode.ERROR, str(exc.response.status_code))
            log.warning("DEP  %s  status=%d  elapsed=%.2fs", dep_name, exc.response.status_code, elapsed)
            return None
        except Exception as exc:
            elapsed = time.monotonic() - start
            DEP_CALL_TOTAL.labels(dependency=dep_name, result="error").inc()
            span.set_status(StatusCode.ERROR, str(exc))
            log.warning("DEP  %s  error=%s", dep_name, exc)
            return None


# ---------------------------------------------------------------------------
# Redis cache read with dedicated trace span
# ---------------------------------------------------------------------------
async def _cache_read(r: aioredis.Redis, cache_k: str) -> Optional[str]:
    """Read from Redis answer cache with an instrumented span for Tempo."""
    with tracer.start_as_current_span("redis.cache.get") as span:
        span.set_attribute("cache.key", cache_k)
        try:
            value = await r.get(cache_k)
            span.set_attribute("cache.hit", value is not None)
            if value is not None:
                span.set_status(StatusCode.OK)
            return value
        except Exception as exc:
            span.set_status(StatusCode.ERROR, str(exc))
            log.warning("CACHE  read error: %s", exc)
            return None


# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------
_request_history: list = []   # for rolling availability SLO


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.client = httpx.AsyncClient()
    app.state.redis = aioredis.from_url(REDIS_URL, decode_responses=True)
    try:
        await app.state.redis.ping()
        log.info("Redis connected at %s", REDIS_URL)
    except Exception as exc:
        log.error("Redis connection failed: %s", exc)
    log.info("GenAI chaos service started")
    yield
    await app.state.client.aclose()
    await app.state.redis.aclose()


app = FastAPI(
    title="GenAI Service — Chaos Testing with Toxiproxy, Redis, and Fallbacks",
    lifespan=lifespan,
)


# ---------------------------------------------------------------------------
# SLO tracking helper
# ---------------------------------------------------------------------------
def _record_request_outcome(success: bool) -> None:
    """Track rolling 60s availability for SLO gauge."""
    now = time.monotonic()
    _request_history.append((now, success))
    # Prune entries older than 60s
    cutoff = now - 60.0
    while _request_history and _request_history[0][0] < cutoff:
        _request_history.pop(0)
    if _request_history:
        total = len(_request_history)
        successes = sum(1 for _, s in _request_history if s)
        SLO_AVAILABILITY.set(successes / total)


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------
@app.get("/health")
async def health():
    r: aioredis.Redis = app.state.redis
    try:
        await r.ping()
        redis_status = "ok"
    except Exception:
        redis_status = "unavailable"
    return {
        "status": "ok",
        "redis": redis_status,
    }


@app.get("/metrics")
async def metrics():
    return Response(content=generate_latest(), media_type="text/plain")


@app.get("/cache/status")
async def cache_status():
    """Show all current cache and idempotency keys in Redis."""
    r: aioredis.Redis = app.state.redis
    cache_keys = await r.keys("cache:*")
    idem_keys = await r.keys("idem:*")
    result: dict = {
        "cache_keys": {},
        "idempotency_keys": {},
    }
    for k in cache_keys:
        ttl = await r.ttl(k)
        result["cache_keys"][k] = {"ttl_seconds": ttl}
    for k in idem_keys:
        val = await r.get(k)
        ttl = await r.ttl(k)
        try:
            parsed = json.loads(val) if val else None
        except Exception:
            parsed = val
        result["idempotency_keys"][k] = {
            "value": parsed,
            "ttl_seconds": ttl,
        }
    return result


@app.post("/ask")
async def ask(
    payload: Optional[dict] = Body(None),
    idempotency_key: Optional[str] = Header(None),
):
    """
    Main GenAI endpoint.
    - Routes calls via Toxiproxy (chaos layer)
    - Falls back to Redis answer cache when retrieval or model fails
    - Marks response degraded=true when cache is used
    - Respects Idempotency-Key header for safe retries
    """
    question = (payload or {}).get("question", "What is GenAI reliability?")
    start = time.monotonic()
    REQUEST_TOTAL.labels(endpoint="/ask").inc()

    client: httpx.AsyncClient = app.state.client
    r: aioredis.Redis = app.state.redis

    cache_k = _cache_key(question)
    degraded = False
    fallback_reason = None

    with tracer.start_as_current_span("ask.handler", kind=SpanKind.SERVER) as root_span:
        root_span.set_attribute("question.hash", cache_k)
        if idempotency_key:
            root_span.set_attribute("idempotency.key", idempotency_key)

        # ── Idempotency check ──────────────────────────────────────────────
        if idempotency_key:
            idem_k = _idem_key(idempotency_key)
            existing = await r.get(idem_k)
            if existing:
                try:
                    stored = json.loads(existing)
                except Exception:
                    stored = {"status": "unknown"}
                status = stored.get("status")
                if status == "succeeded":
                    IDEMPOTENCY_HITS.inc()
                    log.info("IDEM  key=%s  status=succeeded  returning stored result", idempotency_key)
                    root_span.set_attribute("idempotency.hit", True)
                    root_span.set_attribute("idempotency.status", "succeeded")
                    _record_request_outcome(True)
                    return stored.get("result", {})
                if status == "in-progress":
                    log.info("IDEM  key=%s  status=in-progress  returning 202", idempotency_key)
                    root_span.set_attribute("idempotency.status", "in-progress")
                    raise HTTPException(
                        status_code=202,
                        detail={"status": "in-progress", "message": "Tool call is still executing"},
                    )

        # ── Vector retrieval via Toxiproxy ─────────────────────────────────
        context = []
        with tracer.start_as_current_span("vector_db.search") as vec_span:
            vec_resp = await _call_dependency(
                client, "POST", f"{VECTOR_DB_URL}/search",
                dep_name="vector_db",
                timeout=VECTOR_TIMEOUT_S,
                json={"query": question, "top_k": 3},
            )
            if vec_resp:
                context = vec_resp.json().get("results", [])
                CACHE_MISSES.labels(dependency="vector_db").inc()
                vec_span.set_attribute("vector.source", "live")
                vec_span.set_attribute("vector.result_count", len(context))
            else:
                # Retrieval failed — check answer cache (instrumented span)
                cached_answer = await _cache_read(r, cache_k)
                if cached_answer:
                    CACHE_HITS.labels(dependency="vector_db").inc()
                    DEGRADED_RESPONSES.labels(reason="retrieval_timeout").inc()
                    degraded = True
                    fallback_reason = "retrieval_timeout_cache_served"
                    vec_span.set_attribute("vector.source", "cache")
                    vec_span.set_attribute("vector.degraded", True)
                    log.warning("CACHE  vector_db  miss on live call  serving cached answer")
                    elapsed = time.monotonic() - start
                    REQUEST_LATENCY.labels(endpoint="/ask").observe(elapsed)
                    _record_request_outcome(True)
                    result = {
                        "answer": json.loads(cached_answer).get("answer", ""),
                        "latency_ms": round(elapsed * 1000),
                        "degraded": True,
                        "fallback_reason": fallback_reason,
                        "cache_key": cache_k,
                    }
                    return result
                else:
                    # No cache entry either — continue with empty context
                    CACHE_MISSES.labels(dependency="vector_db").inc()
                    vec_span.set_attribute("vector.source", "none")
                    log.warning("CACHE  vector_db  no cache entry  continuing with empty context")

        # ── Model inference via Toxiproxy ──────────────────────────────────
        with tracer.start_as_current_span("model_api.generate") as model_span:
            model_resp = await _call_dependency(
                client, "POST", f"{MODEL_API_URL}/generate",
                dep_name="model_api",
                timeout=MODEL_TIMEOUT_S,
                json={"prompt": question, "context": context},
            )
            if model_resp:
                answer = model_resp.json().get("text", "")
                CACHE_MISSES.labels(dependency="model_api").inc()
                model_span.set_attribute("model.source", "live")
                model_span.set_attribute("model.answer_length", len(answer))
            else:
                # Model failed — check answer cache (instrumented span)
                cached_answer = await _cache_read(r, cache_k)
                if cached_answer:
                    CACHE_HITS.labels(dependency="model_api").inc()
                    DEGRADED_RESPONSES.labels(reason="model_timeout").inc()
                    degraded = True
                    fallback_reason = "model_timeout_cache_served"
                    model_span.set_attribute("model.source", "cache")
                    model_span.set_attribute("model.degraded", True)
                    log.warning("CACHE  model_api  miss on live call  serving cached answer")
                    elapsed = time.monotonic() - start
                    REQUEST_LATENCY.labels(endpoint="/ask").observe(elapsed)
                    _record_request_outcome(True)
                    result = {
                        "answer": json.loads(cached_answer).get("answer", ""),
                        "latency_ms": round(elapsed * 1000),
                        "degraded": True,
                        "fallback_reason": fallback_reason,
                        "cache_key": cache_k,
                    }
                    return result
                else:
                    # No cache — service unavailable
                    CACHE_MISSES.labels(dependency="model_api").inc()
                    model_span.set_attribute("model.source", "none")
                    model_span.set_status(StatusCode.ERROR, "model_unavailable_no_cache")
                    log.error("MODEL  unavailable and no cache entry  returning 503")
                    _record_request_outcome(False)
                    raise HTTPException(status_code=503, detail="Model API unavailable and no cached response")

        # ── Success — store in cache ────────────────────────────────────────
        elapsed = time.monotonic() - start
        response_body = {
            "answer": answer,
            "latency_ms": round(elapsed * 1000),
            "degraded": False,
            "fallback_reason": None,
        }

        # Store full answer in Redis cache
        try:
            await r.setex(cache_k, CACHE_TTL_S, json.dumps(response_body))
            log.info("CACHE  stored  key=%s  ttl=%ds", cache_k, CACHE_TTL_S)
            root_span.set_attribute("cache.stored", True)
        except Exception as exc:
            log.warning("CACHE  store failed: %s", exc)

        REQUEST_LATENCY.labels(endpoint="/ask").observe(elapsed)
        root_span.set_attribute("response.degraded", False)
        root_span.set_status(StatusCode.OK)
        _record_request_outcome(True)
        return response_body


@app.post("/tool")
async def tool(
    payload: Optional[dict] = Body(None),
    idempotency_key: Optional[str] = Header(None),
):
    """
    Tool call endpoint with idempotency.
    - Checks idempotency key before executing
    - Sets in-progress state in Redis before tool runs
    - Stores result on completion
    - Returns stored result on retry without re-executing
    """
    action = (payload or {}).get("action", "unknown_tool")
    params = (payload or {}).get("params", {})
    REQUEST_TOTAL.labels(endpoint="/tool").inc()

    r: aioredis.Redis = app.state.redis
    client: httpx.AsyncClient = app.state.client

    with tracer.start_as_current_span("tool.handler", kind=SpanKind.SERVER) as span:
        span.set_attribute("tool.action", action)
        if idempotency_key:
            span.set_attribute("idempotency.key", idempotency_key)

        # ── Idempotency check ──────────────────────────────────────────────
        if idempotency_key:
            idem_k = _idem_key(idempotency_key)
            existing = await r.get(idem_k)
            if existing:
                try:
                    stored = json.loads(existing)
                except Exception:
                    stored = {}
                status = stored.get("status")
                if status == "succeeded":
                    IDEMPOTENCY_HITS.inc()
                    log.info(
                        "IDEM  key=%s  status=succeeded  returning stored result  (tool NOT re-executed)",
                        idempotency_key,
                    )
                    span.set_attribute("idempotency.hit", True)
                    span.set_attribute("idempotency.status", "succeeded")
                    return stored
                if status == "in-progress":
                    log.info("IDEM  key=%s  status=in-progress", idempotency_key)
                    span.set_attribute("idempotency.status", "in-progress")
                    raise HTTPException(
                        status_code=202,
                        detail={"status": "in-progress", "message": "Tool call is still executing"},
                    )

            # ── Mark in-progress BEFORE executing ─────────────────────────
            in_progress_payload = json.dumps({
                "status": "in-progress",
                "action": action,
                "params": params,
                "started_at": time.time(),
            })
            await r.setex(idem_k, IDEMPOTENCY_TTL_S, in_progress_payload)
            IDEMPOTENCY_IN_PROGRESS.inc()
            log.info("IDEM  key=%s  status=in-progress  set in Redis", idempotency_key)
            span.set_attribute("idempotency.status", "in-progress")

        # ── Simulate tool execution (model call as tool) ───────────────────
        tool_result = None
        try:
            model_resp = await _call_dependency(
                client, "POST", f"{MODEL_API_URL}/generate",
                dep_name="model_api_tool",
                timeout=MODEL_TIMEOUT_S,
                json={"prompt": f"Execute tool: {action} with params: {params}", "context": []},
            )
            if model_resp:
                tool_result = {
                    "status": "succeeded",
                    "action": action,
                    "params": params,
                    "result": model_resp.json().get("text", f"Tool {action} executed"),
                    "executed_at": time.time(),
                }
            else:
                tool_result = {
                    "status": "failed",
                    "action": action,
                    "error": "model_unavailable",
                    "executed_at": time.time(),
                }
        except Exception as exc:
            tool_result = {
                "status": "failed",
                "action": action,
                "error": str(exc),
                "executed_at": time.time(),
            }

        # ── Store result in Redis ──────────────────────────────────────────
        if idempotency_key:
            await r.setex(idem_k, IDEMPOTENCY_TTL_S, json.dumps(tool_result))
            IDEMPOTENCY_IN_PROGRESS.dec()
            log.info(
                "IDEM  key=%s  status=%s  result stored in Redis",
                idempotency_key,
                tool_result.get("status"),
            )
            span.set_attribute("idempotency.final_status", tool_result.get("status"))

        if tool_result.get("status") == "failed":
            raise HTTPException(status_code=503, detail=tool_result)

        return tool_result
