# Demo: Retries and Circuit Breakers with HTTPX

When your model API stalls or your vector database starts throttling, retries can either save you or bury you. This demo shows you how to build resilient GenAI service calls using strict time budgets, bounded retries with exponential backoff and jitter, safe failure classification, and circuit breakers that fail fast during dependency brownouts and recover automatically.

## What You Will Learn

- Enforce strict per-dependency time budgets so one slow call cannot hold workers hostage
- Implement exponential backoff with jitter to prevent thundering herd retry storms
- Retry only on safe failure classes — timeouts, 429 rate limits, and 5xx server errors
- Watch a circuit breaker transition through its full lifecycle: closed, open, half-open, and back to closed
- Visualize retry patterns, breaker state, and budget utilization in Prometheus and Grafana

## Prerequisites

- macOS 14+ or Linux
- Docker Desktop with `docker compose`
- Python 3.12+
- `tmux` installed (`brew install tmux` on macOS)
- Ports available: 3000, 8000, 8081, 8082, 9090

## Architecture

```
                 ┌───────────────────────────────┐
                 │        GenAI Service           │
                 │      localhost:8000            │
                 │                               │
                 │  ┌─────────────────────────┐  │
                 │  │  Per-Request Pipeline    │  │
                 │  │                         │  │
                 │  │  1. Time budget (3s/2s) │  │
                 │  │  2. Retry + backoff     │  │
                 │  │  3. Retry budget (20%)  │  │
                 │  │  4. Circuit breaker     │  │
                 │  └────────┬────────┬───────┘  │
                 └───────────┼────────┼──────────┘
                             │        │
                  ┌──────────┘        └──────────┐
                  ▼                               ▼
         ┌────────────────┐             ┌────────────────┐
         │  Model Stub    │             │  Vector Stub   │
         │ localhost:8081 │             │ localhost:8082 │
         │                │             │                │
         │ Modes:         │             │ Modes:         │
         │  healthy       │             │  healthy       │
         │  slow (4-6s)   │             │  slow (3-5s)   │
         │  throttle (429)│             │  throttle (429)│
         │  error (500)   │             │  error (502)   │
         │  flaky         │             │  flaky         │
         │  recovering    │             └────────────────┘
         └────────┬───────┘
                  │
         ┌────────┴────────┐
         │   Prometheus    │──────▶ Scrapes /metrics every 5s
         │ localhost:9090  │
         └────────┬────────┘
                  │
         ┌────────┴────────┐
         │    Grafana      │──────▶ 7-panel resilience dashboard
         │ localhost:3000  │
         └─────────────────┘
```

Both stubs are local with switchable failure modes. No cloud API keys required. You control exactly when timeouts, 429s, and 500s occur so every run is deterministic and repeatable.

## Quick Start

```bash
# Navigate to the demo directory
cd demo-clip2-retries-circuit-breakers

# Start everything — containers, stubs, app, tmux session
bash scripts/demo_up.sh

# Verify all services (all 8 checks must pass)
bash scripts/preflight_check.sh

# Run the full traffic story (automated five-phase scenario)
bash scripts/run_story.sh

# Tear down everything
bash scripts/demo_down.sh
```

`demo_up.sh` starts Prometheus, Grafana, model stub, vector stub, and the GenAI service, then opens a tmux session with two panes: T1 (app logs) on top and T2 (demo commands) on the bottom.

## Step-by-Step Walkthrough

Follow these steps after `demo_up.sh` completes. You are in the tmux session with T2 active.

### Step 1 — Inspect Time Budgets

```bash
grep "MODEL_TIMEOUT_S\|VECTOR_TIMEOUT_S" app/main.py | grep "^MODEL\|^VECTOR"
```

Expected output:

```
MODEL_TIMEOUT_S = 3.0  # hard budget for model API
VECTOR_TIMEOUT_S = 2.0  # hard budget for vector DB
```

The model API gets a strict three-second budget. The vector database gets two seconds. Any call exceeding its budget is killed immediately and the worker is freed. In production, you derive these values from P99 latency measured over 30 days, with roughly 20% headroom.

### Step 2 — Trigger Timeout Retries

```bash
bash scripts/set_mode.sh model slow
```

This makes the model stub respond in 4–6 seconds, which exceeds the 3-second budget.

```bash
curl -s -X POST localhost:8000/ask \
  -H 'content-type: application/json' \
  -d '{"question":"budget test"}' | python3 -m json.tool
```

Watch T1 (the log pane). You will see:

```
WARNING  DEP  model_api  attempt=0  status=—  reason=timeout  retryable=True
INFO     RETRY  model_api  attempt=0→1  backoff=0.38s
WARNING  DEP  model_api  attempt=1  status=—  reason=timeout  retryable=True
INFO     RETRY  model_api  attempt=1→2  backoff=0.42s
WARNING  DEP  model_api  attempt=2  status=—  reason=timeout  retryable=True
INFO     RETRY  model_api  attempt=2→3  backoff=1.37s
WARNING  DEP  model_api  attempt=3  status=—  reason=timeout  retryable=True
ERROR    Model API unavailable:
```

**What to observe:**
- Each backoff value is different (jitter) and increasing (exponential). The formula doubles the base delay and adds random jitter so thousands of clients do not retry at the same instant.
- After `MAX_RETRIES` (3 retries = 4 total attempts), the request fails with 503.
- The response in T2 shows `"detail": "Model API unavailable"`.

### Step 3 — Trigger 429 Retries

```bash
bash scripts/set_mode.sh model throttle
```

```bash
curl -s -X POST localhost:8000/ask \
  -H 'content-type: application/json' \
  -d '{"question":"backoff test"}' | python3 -m json.tool
```

The log shows the same retry pattern with a different failure class:

```
WARNING  DEP  model_api  attempt=0  status=429  reason=429  retryable=True
INFO     RETRY  model_api  attempt=0→1  backoff=0.28s
WARNING  DEP  model_api  attempt=1  status=429  reason=429  retryable=True
INFO     RETRY  model_api  attempt=1→2  backoff=0.55s
WARNING  DEP  model_api  attempt=2  status=429  reason=429  retryable=True
INFO     RETRY  model_api  attempt=2→3  backoff=1.49s
```

Check the breaker status:

```bash
curl -s localhost:8000/breaker/status | python3 -m json.tool
```

```json
{
    "model_api": { "state": "CLOSED", "failure_count": 2 },
    "vector_db": { "state": "CLOSED", "failure_count": 0 }
}
```

The breaker is counting failures but has not reached its threshold of 5. A few transient 429s during normal traffic spikes should not trip the breaker.

### Step 4 — Review Safe Failure Classes

```bash
grep -A8 "RETRYABLE_STATUS_CODES\|def _is_retryable" app/main.py | head -14
```

```python
RETRYABLE_STATUS_CODES = {429, 500, 502, 503, 504}

def _is_retryable(exc: Exception) -> tuple[bool, str]:
    """Return (should_retry, reason) for the given exception."""
    if isinstance(exc, httpx.TimeoutException):
        return True, "timeout"
```

Only transient failures that might succeed on the next attempt are retried. A 400 (bad request) or 404 (not found) will never retry because repeating the same bad payload fails every time.

### Step 5 — Establish a Healthy Baseline

```bash
bash scripts/set_mode.sh model healthy
```

```bash
curl -s -X POST localhost:8000/ask \
  -H 'content-type: application/json' \
  -d '{"question":"What is an SLO?"}' | python3 -m json.tool
```

```json
{
    "answer": "Model response for: What is an SLO?",
    "latency_ms": 286,
    "model_breaker": "CLOSED",
    "vector_breaker": "CLOSED"
}
```

Latency around 286ms, both breakers closed. This is your healthy baseline.

### Step 6 — Trip the Circuit Breaker

```bash
bash scripts/set_mode.sh model error
```

Fire 7 requests rapidly:

```bash
for i in 1 2 3 4 5 6 7; do echo "--- $i ---"; curl -s -X POST localhost:8000/ask \
  -H 'content-type: application/json' \
  -d '{"question":"trip"}' | python3 -m json.tool; sleep 0.3; done
```

**What to observe:**
- Requests 1–5 return `"Model API unavailable"` after exhausting all retries (4 attempts each).
- Request 6 returns `"model_api circuit breaker is open"` — the breaker tripped. No retries, instant rejection.
- Request 7 also returns circuit breaker open.

In the T1 log, look for:

```
INFO     BREAKER  model_api  CLOSED → OPEN
WARNING  BREAKER  model_api  OPEN — request rejected
```

Check the status:

```bash
curl -s localhost:8000/breaker/status | python3 -m json.tool
```

```json
{
    "model_api": { "state": "OPEN", "failure_count": 5 },
    "vector_db": { "state": "CLOSED", "failure_count": 0 }
}
```

Model API is OPEN with 5 failures. Vector DB stays CLOSED at 0. Each dependency has its own independent breaker — a model outage does not shut down retrieval.

### Step 7 — Observe Half-Open Recovery

```bash
bash scripts/set_mode.sh model healthy
echo "Waiting 12s for recovery timeout..." && sleep 12
```

After 12 seconds (the `CB_RECOVERY_TIMEOUT_S`), the breaker moves from OPEN to HALF-OPEN and allows exactly 2 probe requests through.

```bash
for i in 1 2 3 4 5; do echo "--- probe $i ---"; curl -s -X POST localhost:8000/ask \
  -H 'content-type: application/json' \
  -d '{"question":"probe"}' | python3 -m json.tool; sleep 0.8; done
```

**What to observe:**
- Probe 1 returns `"model_breaker": "HALF_OPEN"` — the breaker is testing.
- Probe 2 returns `"model_breaker": "CLOSED"` — both probes succeeded, breaker closed.
- Probes 3–5 return `"model_breaker": "CLOSED"` — normal traffic resumed.

In T1 you see the full transition sequence:

```
INFO     BREAKER  model_api  OPEN → HALF_OPEN
INFO     BREAKER  model_api  half-open probe OK (1/2)
INFO     BREAKER  model_api  half-open probe OK (2/2)
INFO     BREAKER  model_api  HALF_OPEN → CLOSED
```

Final status:

```bash
curl -s localhost:8000/breaker/status | python3 -m json.tool
```

```json
{
    "model_api": { "state": "CLOSED", "failure_count": 0 },
    "vector_db": { "state": "CLOSED", "failure_count": 0 }
}
```

Both CLOSED, both at zero. Full recovery confirmed.

### Step 8 — Explore the Grafana Dashboard

Open [http://localhost:3000/d/genai-retries-cb](http://localhost:3000/d/genai-retries-cb) in your browser (login: admin / admin).

| Panel | What It Shows | What to Look For |
|-------|--------------|-----------------|
| Circuit Breaker State | Per-dependency state: CLOSED, OPEN, or HALF-OPEN over time | The "mountain shape" — flat at CLOSED, spike to OPEN, back down to CLOSED |
| Dependency Call Results | Success, failure, retry success, and circuit open counts per dependency | Blue bars (success) shift to orange (failure) then green (circuit open) during injection |
| Retry Attempts by Reason | Retry rate broken down by timeout, 429, and 5xx | Spikes during failure injection, drops to zero when breaker opens |
| Retry Budget Utilisation | Gauge showing retry-to-request ratio per dependency (cap: 20%) | Model API gauge goes red during storms — in production, alert at 50% |
| Breaker Transitions | Count of state transitions: closed→open, open→half_open, half_open→closed | One bar per transition event — confirms the full lifecycle |
| Request Latency P50/P95/P99 | End-to-end latency percentiles | P99 spikes during timeout retries, drops when breaker opens and rejects instantly |
| Request Rate | Inbound requests per second | Steady throughput across all phases |

## Configuration Reference

All values are defined in `app/main.py`:

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `MODEL_TIMEOUT_S` | 3.0 | Hard time budget for model API calls |
| `VECTOR_TIMEOUT_S` | 2.0 | Hard time budget for vector DB calls |
| `MAX_RETRIES` | 3 | Maximum retry attempts per request (4 total attempts) |
| `RETRY_BUDGET_RATIO` | 0.20 | Cap retries at 20% of total requests in sliding window |
| `BACKOFF_BASE_S` | 0.3 | Initial exponential backoff delay |
| `BACKOFF_MAX_S` | 2.0 | Maximum backoff cap |
| `JITTER_RANGE` | 0.5 | Random jitter of ±50% applied to each backoff |
| `CB_FAILURE_THRESHOLD` | 5 | Consecutive failures before breaker opens |
| `CB_RECOVERY_TIMEOUT_S` | 10 | Seconds breaker stays open before half-open probe |
| `CB_HALF_OPEN_MAX_PROBES` | 2 | Successful probes required to close breaker |
| `RETRYABLE_STATUS_CODES` | `{429, 500, 502, 503, 504}` | Only these HTTP status codes trigger retries |

## Retry Budget vs Retry Limit

These two mechanisms work together but protect at different levels:

| Mechanism | Scope | What It Prevents |
|-----------|-------|-----------------|
| Retry Limit (`MAX_RETRIES=3`) | Per request | One request from retrying forever |
| Retry Budget (20% cap) | System-wide sliding window | All requests collectively from generating a retry storm |

During a brownout, individual requests may still have retries remaining, but the budget can block them if total retries across all requests exceed 20% of traffic. This prevents the amplification effect where retries multiply load against an already degraded dependency.

## Circuit Breaker Lifecycle

```
    ┌──────────┐     failure_count >= 5     ┌──────────┐
    │  CLOSED  │ ─────────────────────────▶ │   OPEN   │
    │          │                            │          │
    │ Traffic  │                            │ Instant  │
    │ flows    │                            │ reject   │
    │ normally │     probes succeed (2/2)   │ all reqs │
    │          │ ◀───────────────────────── │          │
    └──────────┘                            └─────┬────┘
                                                  │
                                    recovery_timeout (10s)
                                                  │
                                           ┌──────┴─────┐
                                           │ HALF-OPEN  │
                                           │            │
                                           │ Allow 2    │
                                           │ probe reqs │
                                           └────────────┘
```

- **Closed**: Normal operation. The breaker monitors failure counts.
- **Open**: All requests are rejected instantly without contacting the dependency. Workers are freed immediately.
- **Half-Open**: After the recovery timeout, the breaker allows a limited number of probe requests. If probes succeed, the breaker closes. If any probe fails, the breaker returns to open.

## Stub Modes Reference

Switch modes at any time using `scripts/set_mode.sh`:

```bash
bash scripts/set_mode.sh model slow       # 4-6s response (triggers timeout)
bash scripts/set_mode.sh model throttle   # returns 429
bash scripts/set_mode.sh model error      # returns 500
bash scripts/set_mode.sh model healthy    # normal 100-300ms response
bash scripts/set_mode.sh model flaky      # random mix of all modes
```

| Mode | Model Stub (8081) | Vector Stub (8082) |
|------|------------------|--------------------|
| healthy | 100–300ms, 200 OK | 50–150ms, 200 OK |
| slow | 4–6s (exceeds 3s budget) | 3–5s (exceeds 2s budget) |
| throttle | 429 Too Many Requests | 429 Too Many Requests |
| error | 500 Internal Server Error | 502 Bad Gateway |
| flaky | 60% healthy, 20% slow, 10% 429, 10% 500 | 70% healthy, 15% slow, 10% 429, 5% 502 |
| recovering | First 3 requests fail, then healthy | — |

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `scripts/demo_up.sh` | Start all services, create tmux session with T1 (logs) and T2 (commands) |
| `scripts/demo_down.sh` | Kill all processes, stop containers, clean up |
| `scripts/preflight_check.sh` | Verify all 8 services are running, generates HTML report |
| `scripts/check_health.sh` | Quick health check for all endpoints |
| `scripts/set_mode.sh` | Switch stub failure mode: `set_mode.sh <model\|vector> <mode>` |
| `scripts/run_story.sh` | Automated five-phase traffic scenario (baseline → timeouts → 429 → errors → recovery) |
| `scripts/validate_demo.sh` | Run all demo scenes and verify proof points pass |

## File Structure

```
demo-clip2-retries-circuit-breakers/
├── app/
│   ├── __init__.py
│   ├── main.py                    # GenAI service: retries, backoff, circuit breaker
│   └── stubs/
│       ├── __init__.py
│       ├── model.py               # Model API stub with switchable failure modes
│       └── vector.py              # Vector DB stub with switchable failure modes
├── grafana/
│   └── dashboards/
│       └── dashboard.json         # Source dashboard definition
├── infra/
│   ├── docker-compose.yaml        # Prometheus + Grafana containers
│   ├── grafana/
│   │   ├── dashboards/
│   │   │   └── dashboard.json     # Provisioned dashboard (copied from grafana/)
│   │   └── provisioning/
│   │       ├── dashboards.yml     # Auto-provision dashboards
│   │       └── datasources.yml    # Prometheus datasource
│   └── prometheus/
│       └── prometheus.yml         # Scrape config targeting localhost:8000
├── scripts/
│   ├── demo_up.sh                 # Start everything + tmux
│   ├── demo_down.sh               # Tear down everything
│   ├── preflight_check.sh         # 8-point verification
│   ├── check_health.sh            # Quick health check
│   ├── set_mode.sh                # Switch stub modes
│   ├── run_story.sh               # Automated five-phase scenario
│   └── validate_demo.sh           # Proof-point validation
├── .run/                          # Runtime PIDs and logs (gitignored)
├── .venv/                         # Python virtual environment (gitignored)
├── requirements.txt
└── README.md
```

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| `demo_up.sh` fails on Docker | Docker Desktop not running | Start Docker Desktop, wait for whale icon to stop animating |
| Port 8000/8081/8082 already in use | Previous demo not torn down | `bash scripts/demo_down.sh` then `bash scripts/demo_up.sh` |
| Grafana shows "No data" | Prometheus has not scraped yet | Wait 15 seconds, set time range to "Last 5 minutes", click refresh |
| Grafana dashboard missing | Provisioning files not mounted | Ensure `infra/grafana/dashboards/dashboard.json` exists. Run `cd infra && docker compose down && docker compose up -d` |
| Breaker stuck OPEN between runs | In-memory state persists in process | `bash scripts/demo_down.sh` then `bash scripts/demo_up.sh` (full restart resets breakers) |
| Half-open probes fail | Used "recovering" mode instead of "healthy" | `bash scripts/set_mode.sh model healthy` then wait 12 seconds and retry probes |
| `host.docker.internal` not resolving | Linux does not support this by default | Add `extra_hosts: ["host.docker.internal:host-gateway"]` to services in `docker-compose.yaml` |
| pip install fails | System-managed Python | Use the venv created by `demo_up.sh`: `source .venv/bin/activate` |
| Docker Desktop frozen | Docker process hung | `killall Docker\ Desktop 2>/dev/null; killall com.docker.backend 2>/dev/null` |

## Tear Down

```bash
bash scripts/demo_down.sh
```

This kills the tmux session, stops all application processes by PID and by port, and removes Docker containers. If Docker Desktop itself is frozen, use: `killall Docker\ Desktop 2>/dev/null; killall com.docker.backend 2>/dev/null`
