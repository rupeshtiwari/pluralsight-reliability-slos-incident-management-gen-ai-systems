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
    genai_requests_total,
    genai_tokens_in_total,
    genai_tokens_out_total,
    genai_cost_per_request_dollars,
    genai_quality_proxy_score,
)
from app.deps import call_json

app = FastAPI(title="GenAI SLO Demo (FastAPI + Prometheus)")
# Pre-create outcome series so SLO queries never show "No data" after restart
for o in ("success", "degraded", "fail"):
    genai_requests_total.labels(outcome=o)

class ChatRequest(BaseModel):
    prompt: str
    mode: Optional[str] = None

def estimate_tokens(text: str) -> int:
    return max(1, int(len(text) / 4))

def cost_dollars(tokens_in: int, tokens_out: int) -> float:
    return (tokens_in / 1000) * SETTINGS.cost_per_1k_input_tokens + (tokens_out / 1000) * SETTINGS.cost_per_1k_output_tokens

@app.get("/metrics")
def metrics():
    return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.post("/chat")
async def chat(req: ChatRequest):
    t0 = time.perf_counter()
    outcome = "success"
    retrieval_hit = False

    r = await call_json(f"{SETTINGS.retrieval_base_url}/search", SETTINGS.budget_retrieval_ms)
    genai_dependency_latency_seconds.labels(dependency="retrieval").observe(r.latency_s)
    if not r.ok:
        genai_dependency_errors_total.labels(dependency="retrieval", error_type=r.error_type or "other").inc()
        outcome = "degraded"
    else:
        retrieval_hit = bool((r.payload or {}).get("hit", False))

    m = await call_json(f"{SETTINGS.model_base_url}/complete", SETTINGS.budget_model_ms)
    genai_dependency_latency_seconds.labels(dependency="model").observe(m.latency_s)
    if not m.ok:
        genai_dependency_errors_total.labels(dependency="model", error_type=m.error_type or "other").inc()
        outcome = "fail"

    genai_requests_total.labels(outcome=outcome).inc()

    tokens_in = estimate_tokens(req.prompt)
    tokens_out = 120 if outcome != "fail" else 20
    genai_tokens_in_total.inc(tokens_in)
    genai_tokens_out_total.inc(tokens_out)
    genai_cost_per_request_dollars.observe(cost_dollars(tokens_in, tokens_out))

    if outcome == "fail":
        q = 0.0
    else:
        q = 1.0 if retrieval_hit else 0.6
        if outcome == "degraded":
            q = min(q, 0.5)
    genai_quality_proxy_score.set(q)

    genai_request_latency_seconds.observe(time.perf_counter() - t0)
    return {"outcome": outcome, "quality_proxy_score": q}
