# Demo (Module 1, Clip 4): Health Checks + Deep Synthetic Probes with OpenTelemetry

**Learning objective (LO 1c):** implement liveness, readiness, and synthetic probes that catch **soft failures** and emit **traces + metrics per dependency boundary**.

## What this demo teaches (operator-grade)
You will prove, on screen, three facts:
1) **/live is dumb by design** (it stays green during dependency failure)
2) **/ready is a gating decision** (ok | degraded | down with which boundary failed)
3) **Deep probes are actionable** (a failure points to a trace span + a labeled metric)

## Architecture
- `app/main.py` (FastAPI): `/live`, `/ready`, `/probe/deep`, `/metrics`
- `app/model_stub.py`: stubbed model API with an admin toggle (`normal|429|slow`)
- `app/vector_stub.py`: stubbed vector DB with an admin toggle (`normal|slow|empty|low_score`)
- Docker infra (`infra/docker-compose.yaml`):
  - OpenTelemetry Collector (receives OTLP)
  - Tempo (stores traces)
  - Prometheus (scrapes metrics)
  - Grafana (dashboards + Tempo data source)

## Prereqs (macOS)
1) Run course setup:
```bash
../../setup_all.sh
```
2) Ensure Docker Desktop is running.

## One command: start everything
From this demo folder:
```bash
./scripts/demo_up.sh
```

What it does:
- starts Grafana/Tempo/Prometheus/Collector via Docker
- creates a Python virtual env under `.venv/`
- installs Python deps
- starts `model_stub` on :9001
- starts `vector_stub` on :9002
- starts the app on :8080

## Verify services
```bash
curl -s http://localhost:8080/ | jq
curl -s http://localhost:8080/live | jq
curl -s http://localhost:8080/ready | jq
curl -s http://localhost:8080/probe/deep | jq
```

Expected baseline:
- `/live` => `{ "status": "alive" }`
- `/ready` => `status: ok`
- `/probe/deep` => `status: pass`

## Open Grafana
- Grafana: http://localhost:3000
- Dashboard: **GenAI Health + Probes**

Also useful:
- Prometheus: http://localhost:9090
- Tempo: http://localhost:3200

## The story script (what you record)
Run:
```bash
./scripts/demo_run_story.sh
```

It walks the exact recording beats:
1) baseline pass
2) inject **Model 429**
3) show `/live` still green
4) show `/ready` degraded with boundary=model
5) show deep probe fail (503) + labeled metric increments
6) recovery: return to normal

## Manual failure injection
### Inject Model 429
```bash
curl -s -X POST "http://localhost:9001/admin/mode?mode=429" | jq
```

### Recover model
```bash
curl -s -X POST "http://localhost:9001/admin/mode?mode=normal" | jq
```

### Inject vector “empty retrieval” (soft failure)
```bash
curl -s -X POST "http://localhost:9002/admin/mode?mode=empty" | jq
```

### Recover vector
```bash
curl -s -X POST "http://localhost:9002/admin/mode?mode=normal" | jq
```

## Stop everything
```bash
./scripts/demo_down.sh
```

## Troubleshooting
### Docker can’t scrape localhost on macOS
Prometheus scrapes `host.docker.internal:8080`. If that fails, confirm:
```bash
curl -s http://host.docker.internal:8080/metrics | head
```

### Port already in use
This demo uses ports 8080, 9001, 9002, 3000, 9090, 4317, 3200.
Stop prior runs:
```bash
./scripts/demo_down.sh
```

