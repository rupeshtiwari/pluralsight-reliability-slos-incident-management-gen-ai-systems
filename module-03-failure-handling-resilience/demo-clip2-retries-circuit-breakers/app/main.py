"""
GenAI Service — Retries and Circuit Breakers with HTTPX

Demonstrates:
  - Strict time budgets per dependency (model API, vector DB)
  - Exponential backoff with jitter, retry limits, retry budget
  - Retries only on safe failure classes (timeouts, 429, 5xx)
  - Circuit breaker: closed → open → half-open → closed recovery
"""

import asyncio
import hashlib
import logging
import math
import random
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Optional

import httpx
from fastapi import FastAPI, HTTPException
from prometheus_client import (
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)
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
# Configuration — strict time budgets per dependency
# ---------------------------------------------------------------------------
MODEL_API_URL = "http://localhost:8081"
VECTOR_DB_URL = "http://localhost:8082"

MODEL_TIMEOUT_S = 3.0  # hard budget for model API
VECTOR_TIMEOUT_S = 2.0  # hard budget for vector DB
MAX_RETRIES = 3  # per-request retry ceiling
RETRY_BUDGET_RATIO = 0.20  # max 50% of total requests can be retries (demo headroom)
BACKOFF_BASE_S = 0.3  # initial backoff
BACKOFF_MAX_S = 2.0  # cap for exponential backoff
JITTER_RANGE = 0.5  # ±50 % jitter factor

# Circuit-breaker thresholds
CB_FAILURE_THRESHOLD = 5  # failures to trip breaker
CB_RECOVERY_TIMEOUT_S = 10  # seconds before half-open probe
CB_HALF_OPEN_MAX_PROBES = 2  # successful probes to close

# Safe failure classes for retry
RETRYABLE_STATUS_CODES = {429, 500, 502, 503, 504}

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
    buckets=[0.1, 0.25, 0.5, 1.0, 2.0, 3.0, 5.0, 8.0],
)
DEP_CALL_TOTAL = Counter(
    "genai_dependency_calls_total",
    "Calls to each dependency including retries",
    ["dependency", "result"],  # result: success | retry | failure
)
RETRY_TOTAL = Counter(
    "genai_retries_total",
    "Retry attempts per dependency",
    ["dependency", "reason"],  # reason: timeout | 429 | 5xx
)
RETRY_BUDGET_USED = Gauge(
    "genai_retry_budget_used_ratio",
    "Current retry-budget utilisation (0-1)",
    ["dependency"],
)
BREAKER_STATE = Gauge(
    "genai_circuit_breaker_state",
    "Circuit-breaker state: 0=closed, 1=open, 2=half-open",
    ["dependency"],
)
BREAKER_TRANSITIONS = Counter(
    "genai_circuit_breaker_transitions_total",
    "Circuit-breaker state transitions",
    ["dependency", "from_state", "to_state"],
)


# ---------------------------------------------------------------------------
# Retry-budget tracker
# ---------------------------------------------------------------------------
class RetryBudget:
    """Sliding-window retry budget.

    Caps retries at RETRY_BUDGET_RATIO of total requests measured over
    the last *window* seconds.  Prevents retry storms during brownouts.
    """

    def __init__(
        self,
        ratio: float = RETRY_BUDGET_RATIO,
        window: float = 60.0,
        min_requests: int = 10,
    ):
        self.ratio = ratio
        self.window = window
        self.min_requests = min_requests  # don't enforce until enough data
        self._requests: list[float] = []
        self._retries: list[float] = []

    def record_request(self) -> None:
        self._requests.append(time.monotonic())

    def record_retry(self) -> None:
        self._retries.append(time.monotonic())

    def _prune(self) -> None:
        cutoff = time.monotonic() - self.window
        self._requests = [t for t in self._requests if t > cutoff]
        self._retries = [t for t in self._retries if t > cutoff]

    def allows_retry(self) -> bool:
        self._prune()
        total = len(self._requests)
        if total < self.min_requests:
            return True  # not enough data to enforce budget
        return (len(self._retries) / total) < self.ratio

    @property
    def utilisation(self) -> float:
        self._prune()
        total = max(len(self._requests), 1)
        return len(self._retries) / total


# ---------------------------------------------------------------------------
# Circuit breaker
# ---------------------------------------------------------------------------
class BreakerState(Enum):
    CLOSED = 0
    OPEN = 1
    HALF_OPEN = 2


@dataclass
class CircuitBreaker:
    """Per-dependency circuit breaker with closed / open / half-open states."""

    name: str
    failure_threshold: int = CB_FAILURE_THRESHOLD
    recovery_timeout: float = CB_RECOVERY_TIMEOUT_S
    half_open_max: int = CB_HALF_OPEN_MAX_PROBES

    state: BreakerState = field(default=BreakerState.CLOSED, init=False)
    _failure_count: int = field(default=0, init=False)
    _last_failure_time: float = field(default=0.0, init=False)
    _half_open_successes: int = field(default=0, init=False)

    def __post_init__(self) -> None:
        BREAKER_STATE.labels(dependency=self.name).set(self.state.value)

    # -- state transitions ---------------------------------------------------
    def _transition(self, new: BreakerState) -> None:
        old = self.state
        if old == new:
            return
        log.info("BREAKER  %s  %s → %s", self.name, old.name, new.name)
        BREAKER_TRANSITIONS.labels(
            dependency=self.name,
            from_state=old.name.lower(),
            to_state=new.name.lower(),
        ).inc()
        self.state = new
        BREAKER_STATE.labels(dependency=self.name).set(new.value)

    # -- public API ----------------------------------------------------------
    def allow_request(self) -> bool:
        if self.state == BreakerState.CLOSED:
            return True
        if self.state == BreakerState.OPEN:
            elapsed = time.monotonic() - self._last_failure_time
            if elapsed >= self.recovery_timeout:
                self._transition(BreakerState.HALF_OPEN)
                self._half_open_successes = 0
                return True  # allow probe
            return False
        # HALF_OPEN — allow limited probes
        return True

    def record_success(self) -> None:
        if self.state == BreakerState.HALF_OPEN:
            self._half_open_successes += 1
            log.info(
                "BREAKER  %s  half-open probe OK (%d/%d)",
                self.name,
                self._half_open_successes,
                self.half_open_max,
            )
            if self._half_open_successes >= self.half_open_max:
                self._failure_count = 0
                self._transition(BreakerState.CLOSED)
        else:
            self._failure_count = 0

    def record_failure(self) -> None:
        self._failure_count += 1
        self._last_failure_time = time.monotonic()
        if self.state == BreakerState.HALF_OPEN:
            self._transition(BreakerState.OPEN)
        elif self._failure_count >= self.failure_threshold:
            self._transition(BreakerState.OPEN)


# ---------------------------------------------------------------------------
# Resilient HTTPX caller
# ---------------------------------------------------------------------------
def _backoff_delay(attempt: int) -> float:
    """Exponential backoff with jitter."""
    base = min(BACKOFF_BASE_S * (2**attempt), BACKOFF_MAX_S)
    jitter = base * JITTER_RANGE * (2 * random.random() - 1)
    return max(0, base + jitter)


def _is_retryable(exc: Exception) -> tuple[bool, str]:
    """Return (should_retry, reason) for the given exception."""
    if isinstance(exc, httpx.TimeoutException):
        return True, "timeout"
    if isinstance(exc, httpx.HTTPStatusError):
        code = exc.response.status_code
        if code == 429:
            return True, "429"
        if code >= 500:
            return True, "5xx"
    return False, "non_retryable"


async def resilient_call(
    client: httpx.AsyncClient,
    method: str,
    url: str,
    *,
    dep_name: str,
    breaker: CircuitBreaker,
    budget: RetryBudget,
    timeout: float,
    **kwargs: Any,
) -> httpx.Response:
    """Call a dependency with timeout, retries, budget, and circuit breaker."""

    budget.record_request()
    RETRY_BUDGET_USED.labels(dependency=dep_name).set(budget.utilisation)

    # -- breaker gate --------------------------------------------------------
    if not breaker.allow_request():
        DEP_CALL_TOTAL.labels(dependency=dep_name, result="circuit_open").inc()
        log.warning("BREAKER  %s  OPEN — request rejected", dep_name)
        raise HTTPException(
            status_code=503,
            detail=f"{dep_name} circuit breaker is open",
        )

    # -- attempt loop --------------------------------------------------------
    last_exc: Optional[Exception] = None
    for attempt in range(MAX_RETRIES + 1):
        try:
            resp = await client.request(
                method,
                url,
                timeout=timeout,
                **kwargs,
            )
            resp.raise_for_status()
            breaker.record_success()
            label = "success" if attempt == 0 else "retry_success"
            DEP_CALL_TOTAL.labels(dependency=dep_name, result=label).inc()
            log.info(
                "DEP  %s  attempt=%d  status=%d  OK",
                dep_name,
                attempt,
                resp.status_code,
            )
            return resp

        except Exception as exc:
            retryable, reason = _is_retryable(exc)
            status = getattr(getattr(exc, "response", None), "status_code", "—")
            log.warning(
                "DEP  %s  attempt=%d  status=%s  reason=%s  retryable=%s",
                dep_name,
                attempt,
                status,
                reason,
                retryable,
            )
            last_exc = exc

            if not retryable:
                breaker.record_failure()
                DEP_CALL_TOTAL.labels(dependency=dep_name, result="failure").inc()
                raise

            RETRY_TOTAL.labels(dependency=dep_name, reason=reason).inc()

            if attempt >= MAX_RETRIES:
                break

            if not budget.allows_retry():
                log.warning(
                    "BUDGET  %s  retry budget exhausted (%.0f%%)",
                    dep_name,
                    budget.utilisation * 100,
                )
                break

            delay = _backoff_delay(attempt)
            log.info(
                "RETRY  %s  attempt=%d→%d  backoff=%.2fs",
                dep_name,
                attempt,
                attempt + 1,
                delay,
            )
            budget.record_retry()
            RETRY_BUDGET_USED.labels(dependency=dep_name).set(budget.utilisation)
            await asyncio.sleep(delay)

    # -- exhausted retries ---------------------------------------------------
    breaker.record_failure()
    DEP_CALL_TOTAL.labels(dependency=dep_name, result="failure").inc()
    raise last_exc  # type: ignore[misc]


# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------
model_breaker = CircuitBreaker(name="model_api")
vector_breaker = CircuitBreaker(name="vector_db")
model_budget = RetryBudget()
vector_budget = RetryBudget()


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.client = httpx.AsyncClient()
    log.info("GenAI service started")
    yield
    await app.state.client.aclose()


app = FastAPI(title="GenAI Service — Retries & Circuit Breakers", lifespan=lifespan)


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "model_breaker": model_breaker.state.name,
        "vector_breaker": vector_breaker.state.name,
    }


@app.get("/metrics")
async def metrics():
    return Response(content=generate_latest(), media_type="text/plain")


@app.post("/ask")
async def ask(payload: Optional[dict] = None):
    """Main GenAI endpoint — calls model API and vector DB with resilience."""
    question = (payload or {}).get("question", "What is GenAI reliability?")
    start = time.monotonic()
    REQUEST_TOTAL.labels(endpoint="/ask").inc()

    client: httpx.AsyncClient = app.state.client

    # --- vector retrieval ---------------------------------------------------
    try:
        vec_resp = await resilient_call(
            client,
            "POST",
            f"{VECTOR_DB_URL}/search",
            dep_name="vector_db",
            breaker=vector_breaker,
            budget=vector_budget,
            timeout=VECTOR_TIMEOUT_S,
            json={"query": question, "top_k": 3},
        )
        context = vec_resp.json().get("results", [])
    except Exception as exc:
        log.error("Vector DB unavailable: %s", exc)
        context = []

    # --- model inference ----------------------------------------------------
    try:
        model_resp = await resilient_call(
            client,
            "POST",
            f"{MODEL_API_URL}/generate",
            dep_name="model_api",
            breaker=model_breaker,
            budget=model_budget,
            timeout=MODEL_TIMEOUT_S,
            json={"prompt": question, "context": context},
        )
        answer = model_resp.json().get("text", "")
    except HTTPException:
        raise
    except Exception as exc:
        log.error("Model API unavailable: %s", exc)
        raise HTTPException(status_code=503, detail="Model API unavailable")

    elapsed = time.monotonic() - start
    REQUEST_LATENCY.labels(endpoint="/ask").observe(elapsed)

    return {
        "answer": answer,
        "latency_ms": round(elapsed * 1000),
        "model_breaker": model_breaker.state.name,
        "vector_breaker": vector_breaker.state.name,
    }


@app.get("/breaker/status")
async def breaker_status():
    """Inspect circuit-breaker state for both dependencies."""
    return {
        "model_api": {
            "state": model_breaker.state.name,
            "failure_count": model_breaker._failure_count,
        },
        "vector_db": {
            "state": vector_breaker.state.name,
            "failure_count": vector_breaker._failure_count,
        },
    }
