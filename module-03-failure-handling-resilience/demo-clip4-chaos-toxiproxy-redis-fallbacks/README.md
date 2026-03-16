# Chaos Testing with Toxiproxy, Redis, and Fallbacks

A production-grade GenAI service demo that injects real network failures using Toxiproxy, proves Redis cache fallbacks keep the service alive, demonstrates idempotent tool calls with transactional boundaries, and validates everything against SLO targets using Prometheus, Grafana, and Tempo traces.

Built for the Pluralsight course: **Reliability, SLOs, and Incident Management for GenAI Systems**

## What This Demo Proves

- **Graceful degradation:** When the vector database or model API fails, the service serves cached responses and returns `degraded: true` instead of crashing
- **Cache boundary honesty:** When both dependencies fail and no cached answer exists, the service returns a clean 503 — not a hallucinated response
- **Idempotent tool calls:** A tool call writes `in-progress` to Redis before executing, so retries see the state and never double-execute
- **Chaos engineering at the network layer:** Toxiproxy injects latency and connection resets between the app and its dependencies without touching application code
- **SLO validation under chaos:** Prometheus gauges confirm availability and P99 latency stayed within targets through the entire chaos run
- **Trace-level proof:** Grafana Tempo traces show exactly which span timed out and which cache span saved the request

## Architecture

```
                 ┌──────────────────────────────────┐
                 │         GenAI Service             │
                 │       localhost:8000              │
                 │                                  │
                 │  ┌────────────────────────────┐  │
                 │  │   /ask pipeline             │  │
                 │  │   1. Vector retrieval (2s)  │  │
                 │  │   2. Model inference (3s)   │  │
                 │  │   3. Redis cache fallback   │  │
                 │  │   4. Degraded flag + trace  │  │
                 │  └──────┬─────────┬──────────┘  │
                 │         │         │              │
                 │  ┌──────┴─────────┴──────────┐  │
                 │  │   /tool pipeline            │  │
                 │  │   1. Idempotency check      │  │
                 │  │   2. In-progress in Redis   │  │
                 │  │   3. Execute once           │  │
                 │  │   4. Store result           │  │
                 │  └─────────────────────────────┘  │
                 └──────────┬─────────┬──────────────┘
                            │         │
                ┌───────────┘         └───────────┐
                ▼                                  ▼
     ┌─────────────────┐                ┌─────────────────┐
     │   Toxiproxy     │                │   Toxiproxy     │
     │  :8091 → :8081  │                │  :8092 → :8082  │
     │  model-api      │                │  vector-db      │
     └────────┬────────┘                └────────┬────────┘
              ▼                                   ▼
     ┌─────────────────┐                ┌─────────────────┐
     │  Model Stub     │                │  Vector Stub    │
     │  :8081          │                │  :8082          │
     └─────────────────┘                └─────────────────┘

  Redis :6379 │ Prometheus :9090 │ Tempo :3200 │ Grafana :3000
```

## Prerequisites

- macOS 14+ or Linux
- Docker Desktop with `docker compose`
- Python 3.9+
- `tmux` installed (`brew install tmux` on macOS)
- Ports available: 3000, 3200, 4317, 4318, 6379, 8000, 8081, 8082, 8091, 8092, 8474, 9090

## Quick Start

```bash
# Start everything
bash scripts/demo_up.sh

# Verify all services are healthy (15/15 must pass)
bash scripts/preflight_check.sh

# Run the full chaos story to populate Grafana
bash scripts/run_story.sh

# Open Grafana
open http://localhost:3000
```

## Demo Walkthrough

### Scene 1 — Toxiproxy: The Chaos Layer

```bash
# View the proxy configuration
curl -s localhost:8474/proxies | python3 -m json.tool

# Send a baseline request — both dependencies healthy
curl -s -X POST localhost:8000/ask \
  -H 'content-type: application/json' \
  -d '{"question":"What is an SLO?"}' | python3 -m json.tool
```

Response shows `"degraded": false`. Clean starting point.

### Scene 2 — Latency Injection: Cache Fallback

```bash
# Inject 2500ms latency on vector DB (budget is 2 seconds — this will timeout)
bash scripts/set_toxic.sh vector latency 2500

# Same question — now served from cache
curl -s -X POST localhost:8000/ask \
  -H 'content-type: application/json' \
  -d '{"question":"What is an SLO?"}' | python3 -m json.tool

# Check Redis cache state
curl -s localhost:8000/cache/status | python3 -m json.tool

# Remove toxic — automatic recovery
bash scripts/clear_toxics.sh vector
```

Response shows `"degraded": true, "fallback_reason": "retrieval_timeout_cache_served"`.

### Scene 3 — Model Failure + Cache Boundary

```bash
# Kill model connections
bash scripts/set_toxic.sh model reset_peer 0

# Vector succeeds, model fails — cache serves
curl -s -X POST localhost:8000/ask \
  -H 'content-type: application/json' \
  -d '{"question":"What is an SLO?"}' | python3 -m json.tool

# Stack vector failure on top — both dependencies down
bash scripts/set_toxic.sh vector latency 2500

# Uncached question — proves the cache boundary
curl -s -X POST localhost:8000/ask \
  -H 'content-type: application/json' \
  -d '{"question":"Explain quantum gravity on Mars"}' | python3 -m json.tool

# Clean up
bash scripts/clear_toxics.sh all
```

The uncached question returns `503 — Model API unavailable and no cached response`.

### Scene 4 — Idempotent Tool Calls

```bash
# Slow the model so you can inspect Redis mid-flight
bash scripts/set_toxic.sh model latency 2500

# Send tool call with idempotency key
curl -s -X POST localhost:8000/tool \
  -H 'content-type: application/json' \
  -H 'Idempotency-Key: demo-key-001' \
  -d '{"action":"book_meeting","params":{"time":"3pm"}}' | python3 -m json.tool

# Send the exact same request — tool does NOT re-execute
curl -s -X POST localhost:8000/tool \
  -H 'content-type: application/json' \
  -H 'Idempotency-Key: demo-key-001' \
  -d '{"action":"book_meeting","params":{"time":"3pm"}}' | python3 -m json.tool

# Clean up
bash scripts/clear_toxics.sh model
```

App logs show `IDEM key=demo-key-001 status=succeeded returning stored result (tool NOT re-executed)`.

### Scene 5 — SLO Validation

```bash
bash scripts/s5_slo_validation.sh
```

Output: `Availability SLO: 1` and `P99 latency: ~2.98 seconds`.

### Scene 6 — Grafana + Tempo Traces

Open `http://localhost:3000` and check the dashboard:

| Panel                       | What to look for                                   |
| --------------------------- | -------------------------------------------------- |
| Cache Hit Rate              | Spikes during fallback activations                 |
| Degraded Response Rate      | `retrieval_timeout` and `model_timeout` labels     |
| Idempotency Key Hits        | Non-zero from duplicate tool calls                 |
| Request Latency P50/P95/P99 | P99 spike to ~3s during chaos, settled after       |
| SLO Availability            | 100% green                                         |
| SLO P99 Latency             | Under 4 seconds                                    |
| Dependency Call Results     | model_api errors during reset, recovery to success |

Navigate to **Explore → Tempo** and search for `genai-chaos-service` to inspect degraded traces with `redis.cache.get` spans.

## Teardown

```bash
bash scripts/demo_down.sh
```

## Project Structure

```
├── app/
│   ├── main.py              # GenAI service with cache fallbacks and idempotency
│   └── stubs/
│       ├── model.py          # Model API stub (localhost:8081)
│       └── vector.py         # Vector DB stub (localhost:8082)
├── scripts/
│   ├── demo_up.sh            # Start everything + tmux session
│   ├── demo_down.sh          # Stop everything
│   ├── preflight_check.sh    # Verify all 15 services/endpoints
│   ├── run_story.sh          # Full chaos story for Grafana data
│   ├── set_toxic.sh          # Inject Toxiproxy toxic
│   ├── clear_toxics.sh       # Remove toxics
│   ├── check_health.sh       # Health check all services
│   └── s5_slo_validation.sh  # Query Prometheus SLO gauges
├── infra/
│   ├── docker-compose.yaml   # Redis, Toxiproxy, Prometheus, Tempo, Grafana
│   ├── grafana/
│   │   ├── dashboards/       # Dashboard JSON
│   │   └── provisioning/     # Datasource + dashboard provisioning
│   ├── prometheus/            # Prometheus config
│   ├── tempo/                 # Tempo config
│   └── toxiproxy/             # Proxy config (model-api, vector-db)
├── grafana/dashboards/        # Dashboard JSON (alternate mount path)
├── requirements.txt
├── DEMO-STEPS.md              # Step-by-step recording guide
└── NARRATION.md               # Narration script
```

## Key Design Decisions

**Toxiproxy over mock modes:** Clip 2 used stub mode switching (`set_mode.sh`) to simulate failures inside the application. This demo injects failures at the network layer using Toxiproxy — the application code has no knowledge of the chaos. This is how production chaos engineering works.

**Redis for both cache and idempotency:** A single Redis instance serves two purposes — answer caching for fallbacks and idempotency key storage for safe retries. In production you may separate these, but for a GenAI service the access patterns are similar enough to share.

**Rolling SLO window:** The availability gauge uses a 60-second rolling window. A brief 503 ages out quickly, which is correct behavior — SLOs measure sustained reliability, not perfection.

**Dedicated `redis.cache.get` trace span:** Added explicitly so Tempo traces show the cache read as a visible span. Without it, the cache hit is invisible inside the parent `vector_db.search` span.

## Tech Stack

| Component        | Version         | Purpose                         |
| ---------------- | --------------- | ------------------------------- |
| Python / FastAPI | 3.9+ / 0.111.0  | GenAI service                   |
| Redis            | 7.2 Alpine      | Answer cache + idempotency keys |
| Toxiproxy        | 2.9.0 (Shopify) | Network-layer chaos injection   |
| Prometheus       | 2.54.1          | Metrics collection + SLO gauges |
| Grafana          | 11.1.4          | Dashboard visualization         |
| Tempo            | 2.5.0           | Distributed tracing             |
| OpenTelemetry    | 1.25.0          | Trace instrumentation           |

## License

MIT