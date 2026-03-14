# SLO Dashboards, Burn-Rate Alerts, and Feature Freeze Triggers

**Module 2, Clip 4** — Reliability, SLOs and Incident Management for GenAI Systems

This demo builds an SLO compliance dashboard with error budget tracking, multi-window burn-rate alerts, and an automated feature freeze policy gate for a GenAI service.

---

## What You Will Learn

- How a single SLO compliance dashboard gives operators immediate budget visibility
- How multi-window burn-rate alerts distinguish acute incidents from slow degradation
- How alert annotations carry actionable context: severity routing, runbook links, and descriptions
- How error budget policy gates enforce feature freezes automatically when budget is exhausted

---

## Prerequisites

- macOS 14+ or Linux
- Docker Desktop 4.x (engine must be running)
- Python 3.12+
- Ports available: 8080, 9001, 9002, 9003, 9090, 3000

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  GenAI Application (:8080)                              │
│  FastAPI · Prometheus metrics · /chat endpoint           │
├────────────┬──────────────┬─────────────────────────────┤
│ Model Stub │ Retrieval    │ Tools Stub                  │
│ (:9001)    │ Stub (:9002) │ (:9003)                     │
└────────────┴──────────────┴─────────────────────────────┘
        │ scraped by
┌───────▼──────────────────────────────────────────────────┐
│  Prometheus (:9090)                                      │
│  Recording rules: burnrate_5m, burnrate_1h,              │
│                   burnrate_30m, burnrate_6h,             │
│                   error_budget_remaining_demo             │
│  Alert rules: SLOFastBurnPage, SLOSlowBurnTicket         │
└───────┬──────────────────────────────────────────────────┘
        │ datasource
┌───────▼──────────────────────────────────────────────────┐
│  Grafana (:3000)                                         │
│  Dashboard: "SLO Compliance: GenAI API"                  │
└──────────────────────────────────────────────────────────┘
```

The GenAI application exposes Prometheus metrics. Three dependency stubs simulate a model API, a retrieval service, and a tools service. Prometheus scrapes the app, evaluates recording rules that compute burn rates across multiple time windows, and fires alerts when thresholds are breached. Grafana visualizes everything through a pre-provisioned dashboard.

---

## Quick Start

```bash
# Navigate to the demo
cd module-02-slis-slos-slas/demo-clip4-slo-burnrate-freeze

# Verify Docker is running
docker ps

# Start the full stack
./scripts/demo_down.sh
./scripts/demo_up.sh

# Verify everything is healthy (11 checks)
./scripts/preflight_check.sh

# Generate the traffic story
./scripts/run_story.sh

# Open the dashboard
open http://localhost:3000    # login: admin / admin

# Open Prometheus alerts
open http://localhost:9090/alerts
```

---

## What `run_story.sh` Does

The script generates a three-phase traffic story that exercises the full SLO alerting pipeline:

**Phase 1 — Baseline:** Normal traffic, ~270 requests, all outcomes healthy. Burn rate stays low. Error budget remains intact.

**Phase 2 — Model 429 Injection:** Simulates a real provider throttling event. Over 2,000 requests flow through with elevated error rates. Burn rate spikes and error budget is consumed.

**Phase 3 — Recovery:** Traffic returns to normal. The error budget absorbed the full cost of the incident.

Expected output:
```
[15:46:24] Baseline: good traffic so burn rate is low
[mode] model=normal
[mode] retrieval=normal
[mode] tools=normal
[load] duration=20s mode=normal requests=270

[15:46:44] Inject model 429: fast burn page and freeze trigger
[mode] model=429
[load] duration=75s mode=normal requests=2059

[15:47:59] Recover: back to normal
[mode] model=normal
[load] duration=15s mode=normal requests=203

[15:48:14] Done: open Grafana dashboard SLO Compliance GenAI API
```

---

## Exploring the Dashboard

Open Grafana at `http://localhost:3000` (admin/admin). Navigate to **Dashboards → SLO Compliance: GenAI API**. Set time range to **Last 5 minutes** and click refresh.

### Top Row — SLO Status at a Glance

| Panel                        | Expected Value | What It Means                                               |
| ---------------------------- | -------------- | ----------------------------------------------------------- |
| Error Budget Remaining       | **0%**         | Every allowed failure for the compliance window is consumed |
| Burn Rate Now (5m)           | **~1000**      | Budget is burning 1,000x faster than sustainable            |
| Fast-Burn Page Alert         | **1**          | Multi-window fast-burn alert has fired, on-call is paged    |
| Feature Freeze (Policy Gate) | **1**          | Deployments are blocked until budget recovers               |

### Second Row — Policy and Slow Burn

| Panel                          | Expected Value | What It Means                                                    |
| ------------------------------ | -------------- | ---------------------------------------------------------------- |
| Slow-Burn Ticket (Policy Gate) | **0**          | Slow-burn has not triggered — degradation was acute, not gradual |
| Policy Branches                | Text panel     | Documents both burn-rate rules and their operational actions     |

### Third Row — Traffic and Burn-Rate Charts

| Panel                         | What To Look For                                                                        |
| ----------------------------- | --------------------------------------------------------------------------------------- |
| Good vs Bad Request Rate (5m) | Green line = healthy traffic, orange dots = requests counted against the budget         |
| Burn Rate (5m and 1h)         | When both lines converge the problem is sustained; when only 5m spikes it was transient |

### Bottom Row — Error Breakdown

| Panel                           | Note                                                                                 |
| ------------------------------- | ------------------------------------------------------------------------------------ |
| Top Dependency Errors (2m rate) | Uses a 2-minute window — shows "No data" if traffic stopped more than ~2 minutes ago |
| Top Error Types (2m rate)       | Same 2-minute window — run `./scripts/run_load.sh` and refresh to populate           |

---

## Exploring the Alerts

Open Prometheus at `http://localhost:9090/alerts`.

### SLOFastBurnPage — FIRING

```yaml
expr: (slo:burnrate_5m > 14.4) and (slo:burnrate_1h > 14.4)
for: 1m
labels:
    service: genai-slo-demo
    severity: page
    slo: good-requests
annotations:
    description: Multi-window burn rate exceeds 14.4x treat as page level
    runbook_url: https://pluralsight.example/runbooks/genai-slo-fastburn
    summary: Fast burn error budget burning too quickly
```

Both the 5-minute and 1-hour burn rates must exceed 14.4x before this alert fires. The multi-window design (from the Google SRE workbook) prevents a single transient spike from paging on-call. The 1-minute `for` clause adds a grace period. Severity `page` routes to PagerDuty in a production Alertmanager configuration.

### SLOSlowBurnTicket — PENDING

```yaml
expr: (slo:burnrate_30m > 2) and (slo:burnrate_6h > 2)
for: 15m
labels:
    service: genai-slo-demo
    severity: ticket
    slo: good-requests
annotations:
    description: Multi-window burn rate exceeds 2x create a ticket
    runbook_url: https://pluralsight.example/runbooks/genai-slo-slowburn
    summary: Slow burn quiet budget drain
```

Wider windows (30-minute and 6-hour) catch steady degradation that accumulates over hours. The 15-minute `for` clause requires sustained violation. Severity `ticket` creates a work item instead of waking someone up.

### Why Two Alerts from One SLO

|                  | Fast Burn                     | Slow Burn                      |
| ---------------- | ----------------------------- | ------------------------------ |
| **Windows**      | 5m and 1h                     | 30m and 6h                     |
| **Threshold**    | 14.4x                         | 2x                             |
| **Grace period** | 1 minute                      | 15 minutes                     |
| **Severity**     | page                          | ticket                         |
| **Action**       | Page on-call + freeze deploys | Create reliability work ticket |
| **Catches**      | Acute incidents (minutes)     | Gradual degradation (hours)    |

Two alerts, same SLO definition, different response urgency. This prevents alert fatigue while catching every category of budget drain.

---

## Policy Branches

The dashboard encodes two operational policies:

**Fast-Burn → page + feature freeze:** When `burnrate_5m > 14.4 AND burnrate_1h > 14.4` for 1 minute, on-call is paged and feature deployments are blocked immediately.

**Slow-Burn → reliability work ticket:** When `burnrate_30m > 2 AND burnrate_6h > 2` for 15 minutes, a ticket is created for the next sprint. No one gets woken up.

---

## Recording Rules

Prometheus evaluates these recording rules to pre-compute burn rates:

| Rule                              | Window      | Purpose                   |
| --------------------------------- | ----------- | ------------------------- |
| `slo:burnrate_5m`                 | 5 minutes   | Fast-burn short window    |
| `slo:burnrate_1h`                 | 1 hour      | Fast-burn long window     |
| `slo:burnrate_30m`                | 30 minutes  | Slow-burn short window    |
| `slo:burnrate_6h`                 | 6 hours     | Slow-burn long window     |
| `slo:error_budget_remaining_demo` | Demo window | Budget remaining as ratio |

---

## Scripts Reference

| Script               | What It Does                                                                              |
| -------------------- | ----------------------------------------------------------------------------------------- |
| `demo_down.sh`       | Stop app processes on ports 8080, 9001–9003 and tear down Grafana/Prometheus containers   |
| `demo_up.sh`         | Start containers, create Python venv, install deps, launch stubs and app, run smoke check |
| `run_story.sh`       | Generate three-phase traffic story: baseline → 429 injection → recovery                   |
| `run_load.sh`        | Generate additional load (useful for refreshing 2m-rate panels)                           |
| `set_mode.sh`        | Switch dependency stub behavior (normal, 429, slow)                                       |
| `check_health.sh`    | Quick health check of all components                                                      |
| `preflight_check.sh` | Full 11-point verification                                                                |

---

## File Structure

```
demo-clip4-slo-burnrate-freeze/
├── infra/
│   ├── docker-compose.yaml            # Grafana + Prometheus
│   └── prometheus/
│       ├── prometheus.yml             # Scrape configuration
│       ├── recording.yml              # Burn-rate recording rules
│       └── rules.yml                  # Alert rules
├── scripts/
│   ├── demo_down.sh
│   ├── demo_up.sh
│   ├── run_story.sh
│   ├── run_load.sh
│   ├── set_mode.sh
│   ├── check_health.sh
│   └── preflight_check.sh
├── .run/                              # Runtime logs and PID files (gitignored)
└── README.md
```

---

## Troubleshooting

### Docker Desktop Running But CLI Cannot Connect

**Symptom:**
```
Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?
```

**Fix — Kill and relaunch Docker Desktop:**

```bash
killall Docker\ Desktop 2>/dev/null; killall com.docker.backend 2>/dev/null
```

Wait 10 seconds. Then:

```bash
open -a "Docker"
```

Wait 30 seconds. Verify:

```bash
docker context use desktop-linux
docker ps
```

If `docker ps` returns a table, Docker is connected.

**If `docker ps` still fails, try alternative socket paths:**

```bash
docker -H unix://$HOME/.docker/run/docker.sock ps
```

```bash
docker -H unix://$HOME/Library/Containers/com.docker.docker/Data/docker.sock ps
```

### DOCKER_HOST Environment Variable Conflict

**Symptom:** `docker context use desktop-linux` succeeds but `docker ps` still fails.

**Fix:**

```bash
unset DOCKER_HOST
sed -i '' '/DOCKER_HOST/d' ~/.zshrc
source ~/.zshrc
docker context use desktop-linux
docker ps
```

### Prevent Docker Context Issues Permanently

Add to `~/.zshrc`:

```bash
docker context use desktop-linux > /dev/null 2>&1
```

### "No Data" on 2m-Rate Panels

"Top Dependency Errors" and "Top Error Types" use a 2-minute rate window. They show "No data" if more than ~2 minutes have passed since traffic with errors.

**Fix:** Generate fresh traffic and refresh Grafana within 60 seconds:

```bash
./scripts/run_load.sh
```

### Alerts Stuck in Inactive

Prometheus evaluates alert rules every 30 seconds. Wait 60 seconds after `run_story.sh` finishes, then refresh the Prometheus Alerts page.

### Preflight Failures

Share the log file when asking for help:

```
.run/preflight_YYYYMMDD_HHMMSS.log
```

---

## Tear Down

```bash
./scripts/demo_down.sh
```

Stops all application processes and removes Docker containers. No persistent data is left behind.

## Troubleshooting

### "address already in use" on demo_up.sh

Something is holding a port that the demo needs. Find and kill it manually:

```bash
lsof -nP -iTCP:<PORT> -sTCP:LISTEN
kill -9 <PID>
```

If you want to force-clear all demo ports at once, use this one-liner — but run it manually and intentionally, never as part of an automated script:

```bash
for port in 8080 9001 9002 9003; do lsof -ti tcp:$port | xargs kill -9 2>/dev/null; done
```

> **Why this is not in `demo_down.sh`:** `kill -9` skips graceful shutdown and can leave sockets in TIME_WAIT, which makes the problem worse on an immediate restart. It also masks the real cause — something started outside this demo is holding the port. You need to know that, not silently kill it.

---

### Dashboard shows "No data" after run_story.sh

1. Click **Refresh** once — recording rules evaluate every 2 seconds, there can be a brief lag
2. Confirm time range is **Last 15 minutes**
3. Confirm `run_story.sh` finished (all three phases printed)
4. Check Prometheus is scraping:

```bash
curl -s localhost:9090/api/v1/targets | python3 -m json.tool | grep '"health"'
```

Expected: `"health": "up"`. If `"down"`, restart the stack:

```bash
./scripts/demo_down.sh && ./scripts/demo_up.sh
```

---

### Fast-Burn Page Alert still shows 0 after 90 seconds

The rule has `for: 1m` — it requires the condition to be true for 60 continuous seconds before it fires. Check whether it is pending or the burn rate is not high enough:

```bash
# Check current burn rate
curl -s "localhost:9090/api/v1/query?query=slo:burnrate_5m" | python3 -m json.tool

# Check alert state
curl -s localhost:9090/api/v1/alerts | python3 -m json.tool
```

Burn rate should be well above 14.4 during and shortly after the 429 injection window. If it is not, the recording rules may not have loaded — check:

```bash
docker compose -f infra/docker-compose.yaml logs prometheus | tail -n 20
```

---

### SLOSlowBurnTicket shows 0 — is that a bug?

No. This is expected and correct. `SLOSlowBurnTicket` requires `burnrate_6h > 2` sustained for 15 continuous minutes. A 5-minute demo cannot produce that. The teaching point for this rule is its **definition** — show it in the Alerting UI and explain that it creates a reliability work ticket rather than paging. The stat panel will show 0, and that is fine.

---


## Troubleshooting Docker

### Docker Desktop Running But CLI Cannot Connect

**Symptom:**
```
Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?
```
Docker Desktop UI shows "Engine running" but all `docker` commands fail.

**Root cause:** Docker Desktop engine has hung, or the CLI is pointing to the wrong socket.

**Fix — Step 1: Kill and relaunch Docker Desktop**

```bash
killall Docker\ Desktop 2>/dev/null; killall com.docker.backend 2>/dev/null
```

Wait 10 seconds. Then:

```bash
open -a "Docker"
```

Wait 30 seconds for it to fully start.

**Fix — Step 2: Verify the socket and context**

```bash
docker context ls
```

Confirm `desktop-linux` is listed. Then:

```bash
docker context use desktop-linux
```

Verify the socket file exists:

```bash
ls -la ~/.docker/run/docker.sock
```

Test the connection:

```bash
docker ps
```

If `docker ps` returns a table (even empty), Docker is connected. Run `demo_up.sh`.

**Fix — Step 3: If `docker ps` still fails, try alternative socket paths**

```bash
docker -H unix://$HOME/.docker/run/docker.sock ps
```

If that also fails:

```bash
docker -H unix://$HOME/Library/Containers/com.docker.docker/Data/docker.sock ps
```

**Fix — Step 4: If nothing works, reinstall Docker Desktop**

1. Quit Docker Desktop
2. Delete `/Applications/Docker.app`
3. Download fresh from https://docker.com/products/docker-desktop
4. Install and launch
5. Run `docker context use desktop-linux && docker ps`

### DOCKER_HOST Environment Variable Conflict

**Symptom:** `docker context use desktop-linux` succeeds but `docker ps` still fails.

**Root cause:** A `DOCKER_HOST` environment variable is overriding the context.

**Fix:**

```bash
unset DOCKER_HOST
sed -i '' '/DOCKER_HOST/d' ~/.zshrc
source ~/.zshrc
docker context use desktop-linux
docker ps
```

### Prevent Docker Context Issues Permanently

Add this to your `~/.zshrc` so every new terminal uses the correct context:

```bash
# Ensure Docker CLI uses Docker Desktop context
docker context use desktop-linux > /dev/null 2>&1
```

### demo_up.sh Fails After demo_down.sh

**Symptom:** `demo_up.sh` shows the Docker socket error immediately after `demo_down.sh` runs.

**Root cause:** This is not caused by `demo_down.sh`. That script only kills app processes on ports 8080, 9001, 9002, 9003 and runs `docker compose down`. It does not affect the Docker engine.

**Fix:** Follow the "Docker Desktop Running But CLI Cannot Connect" steps above, then re-run:

```bash
./scripts/demo_down.sh
./scripts/demo_up.sh
./scripts/preflight_check.sh
```

---


## Key PromQL reference

```promql
# Current burn rate (5-minute window)
slo:burnrate_5m

# Error budget remaining (how much of the 30-min window budget is left)
slo:error_budget_remaining_demo

# Good request rate
slo:good_rate_5m

# Raw outcome counts
sum by (outcome) (rate(genai_requests_total[5m]))

# Top dependency errors
topk(3, sum by (dependency) (rate(genai_dependency_errors_total[2m])))
```

---

## SLO targets in this demo

| Parameter | Value |
|---|---|
| SLO target | 99.9% good requests |
| Error budget | 0.1% (budget = 0.001) |
| Fast-burn threshold | 14.4× (fires `SLOFastBurnPage`) |
| Slow-burn threshold | 2× sustained 6h (fires `SLOSlowBurnTicket`) |
| Fast-burn policy output | Feature freeze — no deploys until burn rate clears |
| Slow-burn policy output | Reliability work item created for next sprint |

