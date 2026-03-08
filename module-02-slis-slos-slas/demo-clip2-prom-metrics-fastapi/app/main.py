from __future__ import annotations

import time
from typing import Optional

from fastapi import FastAPI
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel
from prometheus_client import generate_latest, CONTENT_TYPE_LATEST

from app.settings import SETTINGS
from app.metrics import (
    genai_request_latency_seconds,
    genai_dependency_latency_seconds,
    genai_dependency_errors_total,
    genai_tokens_in_total,
    genai_tokens_out_total,
    genai_cost_per_request_dollars,
    genai_cost_per_success_dollars,
    genai_quality_proxy_score,
)
from app.deps import call_json

app = FastAPI(title="GenAI SLI Demo (FastAPI + Prometheus)")


class ChatRequest(BaseModel):
    prompt: str
    mode: Optional[str] = None  # normal | tool_fanout


def estimate_tokens(text: str) -> int:
    # Cheap approximation: ~4 chars/token
    return max(1, int(len(text) / 4))


def cost_dollars(tokens_in: int, tokens_out: int) -> float:
    return (tokens_in / 1000) * SETTINGS.cost_per_1k_input_tokens + (
        tokens_out / 1000
    ) * SETTINGS.cost_per_1k_output_tokens


@app.get("/")
def root():
    return {
        "service": SETTINGS.service_name,
        "routes": ["/chat", "/metrics"],
        "grafana": "http://localhost:3000",
        "prometheus": "http://localhost:9090",
    }


@app.get("/metrics")
def metrics():
    return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/chat")
async def chat(req: ChatRequest):
    t0 = time.perf_counter()
    outcome = "success"
    retrieval_hit = False

    # 1) Retrieval boundary
    r = await call_json(
        f"{SETTINGS.retrieval_base_url}/search", SETTINGS.budget_retrieval_ms
    )
    genai_dependency_latency_seconds.labels(dependency="retrieval").observe(r.latency_s)

    if not r.ok:
        genai_dependency_errors_total.labels(
            dependency="retrieval", error_type=r.error_type or "other"
        ).inc()
        outcome = "degraded"
    else:
        retrieval_hit = bool((r.payload or {}).get("hit", False))

    # 2) Optional tools boundary (fan-out = expensive success)
    tool_calls = 0
    if req.mode == "tool_fanout":
        tool_calls = 5
        for _ in range(tool_calls):
            tr = await call_json(
                f"{SETTINGS.tools_base_url}/call", SETTINGS.budget_tools_ms
            )
            genai_dependency_latency_seconds.labels(dependency="tools").observe(
                tr.latency_s
            )
            if not tr.ok:
                genai_dependency_errors_total.labels(
                    dependency="tools", error_type=tr.error_type or "other"
                ).inc()
                outcome = "degraded"

    # 3) Model boundary
    m = await call_json(f"{SETTINGS.model_base_url}/complete", SETTINGS.budget_model_ms)
    genai_dependency_latency_seconds.labels(dependency="model").observe(m.latency_s)

    if not m.ok:
        genai_dependency_errors_total.labels(
            dependency="model", error_type=m.error_type or "other"
        ).inc()
        outcome = "fail"

    # Tokens + cost (toy)
    tokens_in = estimate_tokens(req.prompt) + (tool_calls * 50)
    tokens_out = 120 if outcome != "fail" else 20

    genai_tokens_in_total.inc(tokens_in)
    genai_tokens_out_total.inc(tokens_out)

    cost = cost_dollars(tokens_in, tokens_out)
    genai_cost_per_request_dollars.observe(cost)
    if outcome == "success":
        genai_cost_per_success_dollars.observe(cost)

    # Quality proxy (0..1)
    if outcome == "fail":
        q = 0.0
    else:
        q = 1.0 if retrieval_hit else 0.6
        if outcome == "degraded":
            q = min(q, 0.5)
    genai_quality_proxy_score.set(q)

    # End-to-end latency
    genai_request_latency_seconds.observe(time.perf_counter() - t0)

    return {
        "outcome": outcome,
        "retrieval_hit": retrieval_hit,
        "tool_calls": tool_calls,
        "tokens_in": tokens_in,
        "tokens_out": tokens_out,
        "cost_dollars": round(cost, 6),
        "quality_proxy_score": q,
    }
