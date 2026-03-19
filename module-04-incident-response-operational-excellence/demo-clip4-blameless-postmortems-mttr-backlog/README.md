# Chaos Testing with Toxiproxy, Redis, and Fallbacks

A production-grade chaos engineering demo for a GenAI service. You inject real network failures using Toxiproxy, prove that Redis cache fallbacks keep the service usable under dependency outages, demonstrate idempotent tool calls that execute exactly once even under retries, and validate the entire chaos run against SLO targets using Prometheus gauges and Grafana Tempo traces.

Built for the Pluralsight course: **Reliability, SLOs, and Incident Management for GenAI Systems** — Module 3 Clip 4.

---

## What You Will Learn

- Inject network-layer latency and connection resets against model API and vector DB using Toxiproxy — without touching application code
- Prove Redis cache fallbacks activate automatically when retrieval or model calls fail, returning `degraded: true` with the cached answer
- Discover the cache boundary — honest 503 when no cached answer exists under total dependency failure
- Demonstrate idempotent tool calls with `in-progress` state visible in app logs mid-flight and `succeeded` state on retry
- Validate SLO availability (100%) and P99 latency (under 4 seconds) from Prometheus after chaos
- Trace degraded requests in Grafana Tempo — see the timeout span, the error marker, and the 1.07ms cache hit span that saved the request

---

## Architecture

```
                 ┌──────────────────────────────────────┐
                 │          GenAI Service :8000          │
                 │                                      │
                 │  /ask pipeline                       │
                 │  1. Vector retrieval via Toxiproxy    │
                 │     timeout budget: 2 seconds         │
                 │  2. Model inference via Toxiproxy     │
                 │     timeout budget: 3 seconds         │
                 │  3. On failure → Redis cache lookup   │
                 │  4. Return degraded: true + cached    │
                 │  5. OpenTelemetry trace spans         │
                 │                                      │
                 │  /tool pipeline                      │
                 │  1. Check idempotency key in Redis    │
                 │  2. Write in-progress to Redis        │
                 │  3. Execute tool (model call)         │
                 │  4. Write succeeded to Redis          │
                 │  5. On retry → return stored result   │
                 └──────────┬──────────┬────────────────┘
                            │          │
               ┌────────────┘          └────────────┐
               ▼                                     ▼
     ┌──────────────────┐                 ┌──────────────────┐
     │   Toxiproxy       │                 │   Toxiproxy       │
     │  :8091 → :8081    │                 │  :8092 → :8082    │
     │  model-api proxy  │                 │  vector-db proxy  │
     │  (inject latency, │                 │  (inject latency, │
     │   reset_peer)     │                 │   reset_peer)     │
     └────────┬──────────┘                 └────────┬──────────┘
              ▼                                      ▼
     ┌──────────────────┐                 ┌──────────────────┐
     │  Model Stub       │                 │  Vector Stub      │
     │  :8081            │                 │  :8082            │
     └──────────────────┘                 └──────────────────┘

  Redis :6379 — answer cache (TTL 300s) + idempotency keys (TTL 600s)
  Toxiproxy Admin :8474 — inject/remove toxics via REST API
  Prometheus :9090 — scrapes /metrics, SLO gauges
  Tempo :3200 — receives OpenTelemetry traces (OTLP gRPC :4317)
  Grafana :3000 — 7 dashboard panels + Tempo trace explorer
```

**Key design:** The app calls dependencies through Toxiproxy proxies (ports 8091/8092), not directly (ports 8081/8082). Toxiproxy sits on the wire. You inject chaos at the network layer without restarting or modifying the application.

---

## Prerequisites

- macOS 14+ or Linux
- Docker Desktop with `docker compose`
- Python 3.9+
- `tmux` installed (`brew install tmux` on macOS)
- Ports available: 3000, 3200, 4317, 4318, 6379, 8000, 8081, 8082, 8091, 8092, 8474, 9090

---

## Quick Start

```bash
# Start everything
bash scripts/demo_up.sh

# Verify all services healthy
bash scripts/preflight_check.sh    # 15/15 must pass

# Populate Grafana with chaos data
bash scripts/run_story.sh

# Open Grafana
open http://localhost:3000

# Teardown
bash scripts/demo_down.sh
```

`demo_up.sh` starts Redis, Toxiproxy, model/vector stubs, the GenAI app, Prometheus, Tempo, and Grafana via Docker. It warms the cache with one baseline request. A tmux session opens with T1 (app logs) and T2 (demo commands). The tmux status bar is hidden automatically.

---

## Timeout Budgets

| Dependency | Timeout | Toxiproxy proxy port | Stub port |
|------------|---------|---------------------|-----------|
| Vector DB | 2 seconds | 8092 | 8082 |
| Model API | 3 seconds | 8091 | 8081 |

Any toxic that pushes response time beyond these budgets triggers a timeout and activates the cache fallback.

---

## Toxic Types Available

```bash
# Add 2500ms latency to vector DB
bash scripts/set_toxic.sh vector latency 2500

# Kill model API connections immediately
bash scripts/set_toxic.sh model reset_peer 0

# Remove all toxics from vector DB
bash scripts/clear_toxics.sh vector

# Remove all toxics from both proxies
bash scripts/clear_toxics.sh all
```

| Toxic type | What it does | Use in demo |
|------------|-------------|-------------|
| `latency <ms>` | Adds downstream latency to every response | Scene 2: vector latency 2500 exceeds 2s budget |
| `reset_peer <ms>` | Drops the TCP connection after N ms (0 = immediate) | Scene 3: model connection reset |
| `bandwidth <rate>` | Limits bytes per second | Not used in demo |

---

## Step-by-Step Demo Walkthrough

### Step 1 — Start Everything

```bash
bash scripts/demo_down.sh
bash scripts/demo_up.sh
bash scripts/preflight_check.sh
```

**Expected output:** 15/15 passed. All [OK] lines visible. T1 shows app logs. T2 shows `$` prompt.

**T1 should show:**
```
Redis connected at redis://localhost:6379
GenAI chaos service started
DEP  vector_db  status=200  elapsed=0.11s  OK
DEP  model_api  status=200  elapsed=0.17s  OK
CACHE  stored  key=cache:605b6e940879922c  ttl=300s
```

That last line is the cache warm — the question "What is an SLO?" is now cached with a 300-second TTL.

**Troubleshooting:**
- Preflight shows fewer than 15 passed → Wait 15 seconds and re-run. Prometheus and Grafana need time to initialize.
- `demo_up.sh` fails at docker compose → Docker Desktop might not be running. Check `docker info`.
- Port busy errors → Run `demo_down.sh` first. If stuck: `lsof -ti tcp:<port> | xargs kill -9`.
- T1 shows old logs from previous run → `demo_up.sh` clears logs at startup. If you still see old data, press `Ctrl+C` in T1 and run `> .run/app.log && tail -f .run/app.log`.

### Step 2 — Verify Toxiproxy Baseline

In T2:
```bash
curl -s localhost:8474/proxies | python3 -m json.tool
```

**Expected:** Two proxies visible:
- `model-api` listening on 8091, upstream 8081
- `vector-db` listening on 8092, upstream 8082
- No toxics on either proxy

```bash
curl -s -X POST localhost:8000/ask \
  -H 'content-type: application/json' \
  -d '{"question":"What is an SLO?"}' | python3 -m json.tool
```

**Expected response:**
```json
{
    "answer": "Model response for: What is an SLO?",
    "degraded": false
}
```

`degraded: false` means both dependencies answered normally. This is your clean baseline.

**Troubleshooting:**
- Response shows `degraded: true` → A toxic is still active from a previous run. Run `bash scripts/clear_toxics.sh all`.
- Connection refused → App not running. Check `curl -s localhost:8000/health`.

### Step 3 — Inject Vector Latency: Cache Fallback Activates

```bash
bash scripts/set_toxic.sh vector latency 2500
```

This adds 2500ms latency to every vector DB response. The app gives vector calls a 2-second budget, so every retrieval will now time out.

```bash
curl -s -X POST localhost:8000/ask \
  -H 'content-type: application/json' \
  -d '{"question":"What is an SLO?"}' | python3 -m json.tool
```

**Expected response:**
```json
{
    "degraded": true,
    "fallback_reason": "retrieval_timeout_cache_served",
    "cache_key": "cache:605b6e940879922c"
}
```

**Check T1 app logs — expected:**
```
WARNING  CACHE  vector_db  miss on live call  serving cached answer
```

**Check Redis cache:**
```bash
curl -s localhost:8000/cache/status | python3 -m json.tool
```

**Expected:** Cache key visible with TTL counting down from 300 seconds (you will see a lower number like 195 or 250 depending on how much time has passed).

**Remove the toxic and confirm recovery:**
```bash
bash scripts/clear_toxics.sh vector
```

```bash
curl -s -X POST localhost:8000/ask \
  -H 'content-type: application/json' \
  -d '{"question":"What is an SLO?"}' | python3 -m json.tool
```

**Expected:** `degraded: false` — automatic recovery, no restart needed.

**Troubleshooting:**
- Response shows 503 instead of degraded → The question was never cached. Run `demo_up.sh` again (it warms the cache at startup).
- `degraded: false` even with toxic active → The toxic was not applied. Check `curl -s localhost:8474/proxies/vector-db/toxics | python3 -m json.tool`.

### Step 4 — Model Failure + Combined Chaos + Cache Boundary

**Step 4a — Model-only failure:**

```bash
bash scripts/set_toxic.sh model reset_peer 0
```

```bash
curl -s -X POST localhost:8000/ask \
  -H 'content-type: application/json' \
  -d '{"question":"What is an SLO?"}' | python3 -m json.tool
```

**Expected:** `degraded: true`, `fallback_reason: "model_timeout_cache_served"` — vector succeeded, model failed, cache served.

**Step 4b — Add vector failure (both dependencies down):**

```bash
bash scripts/set_toxic.sh vector latency 2500
```

```bash
curl -s -X POST localhost:8000/ask \
  -H 'content-type: application/json' \
  -d '{"question":"What is an SLO?"}' | python3 -m json.tool
```

**Expected:** `degraded: true` — both dependencies are down. The fallback fired at vector retrieval and returned before the model was ever called. The first failure in the pipeline short-circuits everything after it.

**Step 4c — Cache boundary (uncached question):**

```bash
curl -s -X POST localhost:8000/ask \
  -H 'content-type: application/json' \
  -d '{"question":"Explain quantum gravity on Mars"}' | python3 -m json.tool
```

**Expected:** 503 with `"detail": "Model API unavailable and no cached response"`. This is the cache boundary — both dependencies down, no cached answer, honest failure.

**T1 app logs should show:**
```
ERROR  MODEL  unavailable and no cache entry  returning 503
```

```bash
bash scripts/clear_toxics.sh all
```

**Troubleshooting:**
- Step 4a shows `retrieval_timeout_cache_served` instead of `model_timeout_cache_served` → Vector toxic from Step 3 was not cleared. Run `bash scripts/clear_toxics.sh all` and start Step 4 fresh.
- Step 4c shows `degraded: true` instead of 503 → The question was cached by `run_story.sh`. Use a unique question that was never sent before.
- T1 does not show `model_timeout` label → This is the bug we fixed by reordering Scene 3 to inject model-only first. If model and vector fail simultaneously, vector fails first and short-circuits before model is called — `model_timeout` never appears.

### Step 5 — Idempotency: Tool Executes Once

```bash
bash scripts/set_toxic.sh model latency 2500
```

**Why 2500ms:** MODEL_TIMEOUT_S is 3.0 seconds. The toxic adds 2500ms + ~200ms stub processing = ~2700ms total, under the 3-second timeout. The tool call succeeds. Using 4000ms would exceed the timeout and cause a 503.

**Send the tool call:**

```bash
curl -s -X POST localhost:8000/tool \
  -H 'content-type: application/json' \
  -H 'Idempotency-Key: demo-key-001' \
  -d '{"action":"book_meeting","params":{"time":"3pm"}}' | python3 -m json.tool
```

**While it blocks (~2.7 seconds), check T1 app logs:**
```
IDEM  key=demo-key-001  status=in-progress  set in Redis
```

That is the transactional boundary. If a retry fires right now, it sees `in-progress` and does not run the tool again.

**After it completes, expected response:**
```json
{
    "status": "succeeded",
    "action": "book_meeting",
    "params": {"time": "3pm"},
    "result": "Model response for: Execute tool: book_meeting with params: {'time': '3pm'}"
}
```

**Send the exact same request again (duplicate):**

```bash
curl -s -X POST localhost:8000/tool \
  -H 'content-type: application/json' \
  -H 'Idempotency-Key: demo-key-001' \
  -d '{"action":"book_meeting","params":{"time":"3pm"}}' | python3 -m json.tool
```

**Expected:** Identical response, same `executed_at` timestamp. The tool did NOT re-execute.

**T1 app logs should show:**
```
IDEM  key=demo-key-001  status=succeeded  returning stored result  (tool NOT re-executed)
```

No new `model_api_tool` HTTP request line — the model was never called.

```bash
bash scripts/clear_toxics.sh model
```

**Troubleshooting:**
- Response shows `action: "unknown_tool"` and `params: {}` → The `Body()` import is missing in `app/main.py`. Verify the import line reads `from fastapi import Body, FastAPI, Header, HTTPException, Request`.
- Tool re-executes on duplicate (new `model_api_tool` line in T1) → The `Idempotency-Key` header is not being received. Verify the endpoint uses `Header(None)` without an alias. ASGI normalizes headers to lowercase — `Header(None, alias="Idempotency-Key")` with mixed case never matches.
- Response shows 503 → Toxic latency exceeds MODEL_TIMEOUT_S. Verify you used `latency 2500` not `latency 4000`.
- T1 never shows `IDEM` lines → Idempotency key not received. Same Header alias bug as above.

### Step 6 — SLO Validation

```bash
bash scripts/s5_slo_validation.sh
```

**Expected output:**
```
--- Availability SLO ---
Availability SLO: 1

--- P99 Latency ---
P99 latency: 2.979 seconds
```

**Availability 1.0** — the gauge uses a rolling 60-second window. The single 503 from the cache boundary test already aged out. Degraded responses count as success because the user received a 200 response.

**P99 ~2.98 seconds** — the cache path returns in about 1 millisecond, keeping tail latency under the 4-second target even with both dependencies down.

**Troubleshooting:**
- Shows "no data" or "nan" → Not enough requests in the rate window. Send baseline traffic first: `for i in 1 2 3 4 5; do curl -s -X POST localhost:8000/ask -H 'content-type: application/json' -d '{"question":"What is an SLO?"}' > /dev/null; sleep 1; done`. Wait 15 seconds and re-run.
- Script crashes with JSON error → Shell mangled the PromQL brackets. The script uses `curl -G --data-urlencode` to handle URL encoding properly. If running manually, always use `--data-urlencode` for PromQL queries.

### Step 7 — Grafana Dashboard

**Populate Grafana first (if not already done):**

```bash
bash scripts/run_story.sh
```

Wait 30 seconds, then open `localhost:3000`. Set time range to **Last 15 minutes**.

**Expected panels (7 total):**

| Panel | Expected |
|-------|----------|
| Cache Hit Rate | Spikes where fallbacks activated (vector_db orange, model_api green). Flat during baseline. |
| Degraded Response Rate | Two labels visible: `retrieval_timeout` (orange) and `model_timeout` (green). Both failure modes independently. |
| Idempotency Key Hits | Green spike from duplicate tool calls in Step 5. |
| Request Latency P50/P95/P99 | P99 jumps to ~3 seconds during chaos, drops after recovery. |
| SLO Availability (target 99%) | Green gauge at 100%. |
| SLO P99 Latency (target < 4s) | Yellow gauge at ~2.98 seconds, under the 4-second target. |
| Dependency Call Results | model_api error spike, model_api success, vector_db success, vector_db timeout all visible. |

**Troubleshooting:**
- All panels show "No data" → Datasource UID mismatch. Check `infra/grafana/provisioning/datasources.yml` has `uid: prometheus` and `uid: tempo`. Restart with `demo_down.sh` + `demo_up.sh`.
- Only some panels have data → `run_story.sh` did not complete all phases. Re-run it and wait 30 seconds.
- SLO gauges show wrong values → Check Grafana time range is "Last 15 minutes" and run_story.sh completed within that window.

### Step 8 — Tempo Traces

In Grafana, navigate to **Explore → Tempo → Search tab**.

Set **Service Name:** `genai-chaos-service` and click **Search**.

**Open a degraded trace (one with ~2 second duration):**

Expected spans:
- `ask.handler` (2 seconds) — the root span, degraded=true
- `vector_db.search` (2 seconds) — the timeout
- `vector_db.call` (2 seconds) — the actual HTTP call with red error marker
- `redis.cache.get` (1.07 milliseconds) — the cache hit that saved the request

**Open a clean trace (one with ~0.3 second duration):**

Expected: All spans green, degraded=false.

**Troubleshooting:**
- No traces found → Tempo is not receiving spans. Check `docker logs clip4-tempo`. Verify `infra/grafana/provisioning/datasources.yml` has `uid: tempo`.
- Traces show but `redis.cache.get` span is missing → The `_cache_read()` helper function with the dedicated trace span must be present in `app/main.py`. This was added specifically for this demo — without it, the cache read is invisible inside the parent `vector_db.search` span.
- Service name not found → The app sets the service name via OpenTelemetry resource: `SERVICE_NAME: genai-chaos-service`. Verify it matches your Tempo search.

### Step 9 — Teardown

```bash
bash scripts/demo_down.sh
```

---

## Project Structure

```
├── app/
│   ├── main.py                    # GenAI service with cache fallbacks, idempotency, OTel traces
│   └── stubs/
│       ├── model.py               # Model API stub (localhost:8081)
│       └── vector.py              # Vector DB stub (localhost:8082)
├── scripts/
│   ├── demo_up.sh                 # Start everything + tmux (status off, log clearing)
│   ├── demo_down.sh               # Stop everything
│   ├── preflight_check.sh         # 15-point health check
│   ├── run_story.sh               # Full chaos story for Grafana data
│   ├── set_toxic.sh               # Inject Toxiproxy toxic (latency, reset_peer, bandwidth)
│   ├── clear_toxics.sh            # Remove toxics from one or all proxies
│   ├── check_health.sh            # Health check all services
│   └── s5_slo_validation.sh       # Query Prometheus SLO gauges
├── infra/
│   ├── docker-compose.yaml        # Redis, Toxiproxy, Prometheus, Tempo, Grafana
│   ├── grafana/
│   │   ├── dashboards/            # Dashboard JSON (7 panels)
│   │   └── provisioning/          # Datasource (uid: prometheus, uid: tempo) + dashboard config
│   ├── prometheus/
│   │   └── prometheus.yml         # Scrape config for app :8000
│   ├── tempo/
│   │   └── tempo.yaml             # Tempo config (OTLP gRPC receiver)
│   └── toxiproxy/
│       └── config.json            # Two proxies: model-api, vector-db
├── grafana/dashboards/
│   └── dashboard.json             # Dashboard JSON (alternate mount path)
├── requirements.txt
├── DEMO-STEPS.md                  # Recording choreography
└── README.md                      # This file
```

---

## Key Design Decisions

**Toxiproxy over mock modes.** Module 3 Clip 2 used stub mode switching (`set_mode.sh`) to simulate failures inside the application. This demo injects failures at the network layer using Toxiproxy — the application code has no knowledge of the chaos. This is how production chaos engineering works. Shopify open sourced Toxiproxy (`ghcr.io/shopify/toxiproxy:2.9.0`) for exactly this purpose.

**Redis for both cache and idempotency.** A single Redis instance serves two purposes — answer caching for fallbacks (TTL 300 seconds) and idempotency key storage for safe retries (TTL 600 seconds). The access patterns are similar enough to share in a GenAI service.

**Rolling SLO window.** The availability gauge uses a 60-second rolling window. A brief 503 ages out quickly, which is correct behavior — SLOs measure sustained reliability, not perfection. Degraded responses (200 with cached answer) count as successes.

**Dedicated `redis.cache.get` trace span.** Added explicitly so Tempo traces show the cache read as a visible span. Without it, the cache hit is invisible inside the parent `vector_db.search` span and the viewer cannot see the 1.07ms that saved the request.

**Scene 3 model-first ordering.** The demo injects model-only failure first (Step 4a), then adds vector failure (Step 4b). If both are injected simultaneously, vector fails first and short-circuits before model is called — the `model_timeout` label never appears in Grafana. Model-first ordering generates both labels.

**Scene 4 toxic at 2500ms, not 4000ms.** MODEL_TIMEOUT_S is 3.0 seconds. A 4000ms toxic + ~200ms stub processing = ~4200ms, exceeding the timeout. The tool call would fail with 503 instead of succeeding. 2500ms + ~200ms = ~2700ms stays under budget.

---

## Bugs We Found and Fixed During Production

These are real issues discovered during demo development. Documented here so you can avoid them.

| Bug | Root cause | Fix |
|-----|-----------|-----|
| Grafana panels show "No data" | `datasources.yml` did not set explicit `uid`. Grafana auto-generates random UIDs and panels cannot find the datasource. | Add `uid: prometheus` and `uid: tempo` to provisioning. |
| Idempotency key not received | `Header(None, alias="Idempotency-Key")` with mixed case. ASGI normalizes headers to lowercase so the alias never matches. | Remove the alias: `Header(None)`. FastAPI auto-converts parameter name to header name. |
| JSON body not parsed | `payload: Optional[dict] = None` without `Body()`. FastAPI treats it as a query parameter. | Change to `Body(None)` and add `Body` to imports. |
| `model_timeout` label missing from Grafana | Both toxics injected simultaneously. Vector fails first, short-circuits before model called. | Inject model-only first, then add vector. |
| Tool call 503 instead of success | Toxic latency 4000ms exceeds MODEL_TIMEOUT_S of 3.0s. | Use 2500ms (total ~2700ms, under budget). |
| SLO script crashes in tmux | Multi-line Python paste breaks in tmux. PromQL brackets mangled by shell. | Use `curl -G --data-urlencode` in a script file. |
| `redis.cache.get` span missing in Tempo | No dedicated trace span for cache read. Cache hit invisible inside parent span. | Added `_cache_read()` helper with `tracer.start_as_current_span("redis.cache.get")`. |
| T1 shows stale logs from previous run | `app.log` not cleared on restart. `tail -f` shows old data. | `demo_up.sh` truncates all logs at startup: `: > .run/app.log`. |
| tmux green status bar visible | Default tmux status bar distracting on camera. | `tmux set-option -g status off` in `demo_up.sh`. |

---

## Tech Stack

| Component | Version | Purpose |
|-----------|---------|---------|
| Python / FastAPI | 3.9+ / 0.111.0 | GenAI service |
| Redis | 7.2 Alpine | Answer cache + idempotency keys |
| Toxiproxy | 2.9.0 (Shopify) | Network-layer chaos injection |
| Prometheus | 2.54.1 | Metrics collection + SLO gauges |
| Grafana | 11.1.4 | Dashboard (7 panels) + Tempo explorer |
| Tempo | 2.5.0 | Distributed tracing |
| OpenTelemetry SDK | 1.25.0 | Trace instrumentation (OTLP gRPC) |
| HTTPX | 0.27.0 | Async HTTP client with timeout support |

---

## Learning Objectives Covered

| LO | Description | Step | Proof |
|----|-------------|------|-------|
| 3b | Cache when retrieval fails | 3 | `degraded: true` + `retrieval_timeout_cache_served` |
| 3b | Cache when model fails | 4a | `model_timeout_cache_served` |
| 3b | Cache boundary (honest 503) | 4c | 503 on uncached question |
| 3c | Idempotent operations | 5 | Same key twice, tool ran once, `(tool NOT re-executed)` in logs |
| 3c | Transactional boundary | 5 | `in-progress` visible in app logs mid-flight |
| 3d | Failure injection | 3, 4 | Toxiproxy toxics added and removed live |
| 3d | Multiple simultaneous failures | 4b | Both proxies down, pipeline short-circuit |
| 3d | Traces as proof | 8 | 4 spans in Tempo — timeout + error + 1.07ms cache hit |
| 3d | SLO validation | 6, 7 | Availability 100%, P99 2.98s, Grafana gauges |

---

## Common Issues and Fixes

| Issue | Cause | Fix |
|-------|-------|-----|
| Preflight fails on "Redis cache empty" | Cache warm did not run | Run `demo_up.sh` again (it warms cache at startup) |
| Preflight fails on Prometheus/Grafana/Tempo | Docker containers starting slowly | Wait 15 seconds, re-run preflight |
| `degraded: false` with toxic active | Wrong proxy or toxic not applied | Check `curl -s localhost:8474/proxies/vector-db/toxics` |
| 503 instead of degraded response | Question not in cache | Use "What is an SLO?" which is cached at startup |
| Idempotency not working | Header alias or Body import bug | See "Bugs We Found" table above |
| SLO script shows "nan" | No request data in rate window | Send 5 baseline requests, wait 15 seconds |
| Grafana "No data" | Missing `uid: prometheus` in datasources | Check provisioning file, restart |
| Tempo shows no traces | OTel exporter not reaching Tempo | Check `docker logs clip4-tempo`, verify port 4317 open |
| tmux green bar visible | Status not disabled | `tmux set -g status off` |
| Ports busy from previous run | Stale processes | `demo_down.sh` then retry. Nuclear: `lsof -ti tcp:8000 | xargs kill -9` |

---

## License

MIT
