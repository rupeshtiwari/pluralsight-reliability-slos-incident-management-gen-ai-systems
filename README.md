# Reliability, SLOs, and Incident Management for GenAI Systems

This repository contains the hands-on demos for the Pluralsight course:

**Reliability, SLOs, and Incident Management for GenAI Systems**

---

## What you will learn

By running these demos you will learn how to operate GenAI systems with an SRE mindset:

- Define service health beyond HTTP 200
- Instrument GenAI SLIs with Prometheus and FastAPI
- Build SLO compliance dashboards with burn-rate alerts and feature freeze triggers
- Implement timeouts, retries with exponential backoff, and circuit breakers
- Run chaos experiments with Toxiproxy and Redis fallbacks
- Build alerting and escalation pipelines with Alertmanager
- Conduct blameless postmortems and track MTTR and reliability backlogs

---

## Repository structure

```text
.
├── README.md
├── course_setup/
│   ├── README.md
│   └── setup_all.sh
├── demos/
│   └── README.md                          ← course-wide demo index
├── module-01-production-reliability-fundamentals/
│   └── demo-clip4-otel-health-probes/
├── module-02-slis-slos-slas/
│   ├── demo-clip2-prom-metrics-fastapi/
│   └── demo-clip4-slo-burnrate-freeze/
├── module-03-failure-handling-resilience/
│   ├── demo-clip2-retries-circuit-breakers/
│   └── demo-clip4-chaos-toxiproxy-redis-fallbacks/
└── module-04-incident-response-operational-excellence/
    ├── demo-clip2-alerting-escalation-alertmanager/
    └── demo-clip4-blameless-postmortems-mttr-backlog/
```

---

## Requirements

- macOS
- Docker Desktop
- Python 3.9 or higher
- Git, curl, jq

---

## One-time setup

From the repository root:

```bash
./course_setup/setup_all.sh
```

Start Docker Desktop and verify:

```bash
open -a Docker
docker version
docker compose version
```

---

## How to run any demo

Every demo follows the same three-step pattern:

### Step 1 — Pre-flight check

Run this before every session. It verifies Docker, ports, services, and the dashboard — and opens an HTML report with fix instructions for anything that fails.

```bash
./scripts/preflight_check.sh
```

All checks must pass before you proceed.

### Step 2 — Start and run

```bash
./scripts/demo_up.sh
./scripts/run_story.sh
```

### Step 3 — Stop

```bash
./scripts/demo_down.sh
```

See `demos/README.md` for the full index of all demos with paths, LOs, and port references.

---

## Demo index

| Module | Clip | Demo | LO |
|--------|------|------|----|
| 1 | 4 | OpenTelemetry Health Checks and Synthetic Probes | 1c |
| 2 | 2 | Instrument GenAI SLIs with Prometheus and FastAPI | 2a |
| 2 | 4 | SLO Dashboards, Burn-Rate Alerts, and Feature Freeze Triggers | 2d |
| 3 | 2 | Retries and Circuit Breakers with HTTPX | 3a |
| 3 | 4 | Chaos Testing with Toxiproxy, Redis, and Fallbacks | 3b, 3c, 3d |
| 4 | 2 | Alerting and Escalation with Prometheus Alertmanager | 4b |
| 4 | 4 | Blameless Postmortems, MTTR Metrics, and Reliability Backlogs | 5a, 5b, 5c |

---

## Troubleshooting

### Docker not responding

Hard restart Docker Desktop on Mac:

```bash
killall Docker\ Desktop 2>/dev/null; killall com.docker.backend 2>/dev/null
sleep 5
open -a Docker
```

Wait for the whale icon to stop animating, then:

```bash
docker context use default
docker info | grep "Server Version"
```

### Port already in use

Find and kill the process holding the port:

```bash
lsof -nP -iTCP:<PORT> -sTCP:LISTEN
kill -9 <PID>
```

### App does not start

Check the application log:

```bash
tail -n 50 .run/app.log
```

---

## Safety notes

All demos run locally using Docker and local Python processes. No cloud resources are created. No API keys are required.
