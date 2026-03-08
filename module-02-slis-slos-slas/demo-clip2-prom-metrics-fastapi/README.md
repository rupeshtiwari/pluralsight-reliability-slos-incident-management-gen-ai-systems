# Demo — Instrument GenAI SLIs with Prometheus Metrics (FastAPI)

Learning objective: **2a** — GenAI SLIs that matter (latency percentiles, error rates, quality proxy, cost per request/success).

## What this demo proves (operator-grade)
1) **Latency percentiles** (P95/P99) for end-to-end and each dependency boundary (retrieval, model, tools)
2) **Error rates** labeled by dependency and error_type (timeout, 429, 5xx)
3) **Cost SLIs**: tokens_in/out, cost_per_request, cost_per_success
4) One **online quality proxy** metric and its limits (proxy ≠ correctness)

## Architecture
- FastAPI app: `:8080` (POST `/chat`, GET `/metrics`)
- Retrieval stub: `:9002`
- Model stub: `:9001`
- Tools stub: `:9003`
- Docker: Prometheus `:9090`, Grafana `:3000`

## Run
```bash
./scripts/demo_up.sh
./scripts/run_story.sh
```

Stop:
```bash
./scripts/demo_down.sh
```

## PromQL (Grafana → Explore → Prometheus → Code)

### End-to-end P95 latency
```promql
histogram_quantile(0.95, sum by (le) (rate(genai_request_latency_seconds_bucket[2m])))
```

### Model P99 latency
```promql
histogram_quantile(0.99, sum by (le) (rate(genai_dependency_latency_seconds_bucket{dependency="model"}[2m])))
```

### Error rate by boundary + type
```promql
sum by (dependency, error_type) (rate(genai_dependency_errors_total[2m]))
```

### Cost per request (avg)
```promql
rate(genai_cost_per_request_dollars_sum[2m]) / rate(genai_cost_per_request_dollars_count[2m])
```

### Cost per success (avg)
```promql
rate(genai_cost_per_success_dollars_sum[2m]) / rate(genai_cost_per_success_dollars_count[2m])
```

### Quality proxy (trend)
```promql
avg_over_time(genai_quality_proxy_score[5m])
```

## Quality proxy definition
`genai_quality_proxy_score` is computed from online signals:
- retrieval non-empty (hit) improves score
- model success improves score
- degraded outcomes reduce score

It is useful for *detection* and *trend*, not ground-truth correctness.
