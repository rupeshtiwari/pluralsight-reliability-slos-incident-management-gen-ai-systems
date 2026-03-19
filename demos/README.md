# Demo Index

**Course:** Reliability, SLOs and Incident Management for GenAI Systems

This folder is a course-wide index of all demos across all modules.

Do not run demos from this folder. Run each demo from its own module directory using the paths below. Nothing needs to be moved into `demos/`.

Each demo folder contains its own `README.md` with full setup, run, troubleshoot, and teardown instructions.

---

## Module 1: Production Reliability Fundamentals for GenAI Systems

### Clip 4: Demo — OpenTelemetry Health Checks and Synthetic Probes

**Learning Objective:** 1c — Implement health checks and synthetic monitoring that continuously verify system components are functioning correctly

**Demo path**
```bash
cd module-01-production-reliability-fundamentals/demo-clip4-otel-health-probes
```

**Pre-flight check**
```bash
./scripts/preflight_check.sh
```

**Start**
```bash
./scripts/demo_up.sh
```

**Run story**
```bash
./scripts/run_story.sh
```

**Stop**
```bash
./scripts/demo_down.sh
```

**Ports:** 8080, 9001, 9002, 9003, 9090, 16686 (Jaeger), 3000 (Grafana)

---

## Module 2: SLIs, SLOs, and SLAs for GenAI Services

### Clip 2: Demo — Instrument GenAI SLIs with Prometheus Metrics in FastAPI

**Learning Objective:** 2a — Define SLIs for availability, latency percentiles, error rates, quality scores, and cost per request

**Demo path**
```bash
cd module-02-slis-slos-slas/demo-clip2-prom-metrics-fastapi
```

**Pre-flight check**
```bash
./scripts/preflight_check.sh
```

**Start**
```bash
./scripts/demo_up.sh
```

**Run story**
```bash
./scripts/run_story.sh
```

**Stop**
```bash
./scripts/demo_down.sh
```

**Ports:** 8080, 9001, 9002, 9003, 9090, 3000

---

### Clip 4: Demo — SLO Dashboards, Burn-Rate Alerts, and Feature Freeze Triggers

**Learning Objective:** 2d — Monitor SLO compliance through dashboards, track error budgets, and use SLO violations as triggers for reliability improvements or feature freeze decisions

**Demo path**
```bash
cd module-02-slis-slos-slas/demo-clip4-slo-burnrate-freeze
```

**Pre-flight check**
```bash
./scripts/preflight_check.sh
```

**Start**
```bash
./scripts/demo_up.sh
```

**Run story**
```bash
./scripts/run_story.sh
```

**Stop**
```bash
./scripts/demo_down.sh
```

**Ports:** 8080, 9001, 9002, 9003, 9090, 3000

---

## Module 3: Failure Handling and Resilience Patterns for GenAI

### Clip 2: Demo — Retries and Circuit Breakers with HTTPX

**Learning Objective:** 3a — Discuss resilience patterns including timeouts, retries with exponential backoff, circuit breakers, bulkheads, and fallbacks

**Demo path**
```bash
cd module-03-failure-handling-resilience/demo-clip2-retries-circuit-breakers
```

**Pre-flight check**
```bash
./scripts/preflight_check.sh
```

**Start**
```bash
./scripts/demo_up.sh
```

**Run story**
```bash
./scripts/run_story.sh
```

**Stop**
```bash
./scripts/demo_down.sh
```

**Ports:** 8080, 9001, 9002, 9003, 9090, 3000

---

### Clip 4: Demo — Chaos Testing with Toxiproxy, Redis, and Fallbacks

**Learning Objectives:** 3b, 3c, 3d — Graceful degradation, idempotency keys, chaos engineering practices

**Demo path**
```bash
cd module-03-failure-handling-resilience/demo-clip4-chaos-toxiproxy-redis-fallbacks
```

**Pre-flight check**
```bash
./scripts/preflight_check.sh
```

**Start**
```bash
./scripts/demo_up.sh
```

**Run story**
```bash
./scripts/run_story.sh
```

**Stop**
```bash
./scripts/demo_down.sh
```

**Ports:** 8080, 9001, 9002, 9003, 9090, 3000, 6379 (Redis), 8474 (Toxiproxy API)

---

## Module 4: Incident Response and Operational Excellence for GenAI

### Clip 2: Demo — Alerting and Escalation with Prometheus Alertmanager

**Learning Objective:** 4b — Build effective alerting systems with severity levels, actionable context, and escalation policies

**Demo path**
```bash
cd module-04-incident-response-operational-excellence/demo-clip2-alerting-escalation-alertmanager
```

**Pre-flight check**
```bash
./scripts/preflight_check.sh
```

**Start**
```bash
./scripts/demo_up.sh
```

**Run story**
```bash
./scripts/run_story.sh
```

**Stop**
```bash
./scripts/demo_down.sh
```

**Ports:** 8080, 9001, 9002, 9003, 9090, 9093 (Alertmanager), 3000

---

### Clip 4: Demo — Blameless Postmortems, MTTR Metrics, and Reliability Backlogs

**Learning Objectives:** 5a, 5b, 5c — Operational metrics, data-driven reliability improvements, SRE culture

**Demo path**
```bash
cd module-04-incident-response-operational-excellence/demo-clip4-blameless-postmortems-mttr-backlog
```

**Pre-flight check**
```bash
./scripts/preflight_check.sh
```

**Start**
```bash
./scripts/demo_up.sh
```

**Run story**
```bash
./scripts/run_story.sh
```

**Stop**
```bash
./scripts/demo_down.sh
```

**Ports:** 8080, 9001, 9002, 9003, 9090, 3000

---

## Docker Desktop hard restart (Mac)

If Docker stops responding at any point across any demo:

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

---

## Common ports reference

| Port | Service |
|------|---------|
| 8080 | FastAPI app |
| 9001 | Model stub |
| 9002 | Retrieval stub |
| 9003 | Tools stub |
| 9090 | Prometheus |
| 9093 | Alertmanager (Module 4 Clip 2 only) |
| 3000 | Grafana |
| 6379 | Redis (Module 3 Clip 4 only) |
| 8474 | Toxiproxy API (Module 3 Clip 4 only) |
| 16686 | Jaeger (Module 1 Clip 4 only) |
