# Alerting and Escalation with Prometheus Alertmanager

A production-grade alerting demo for a GenAI service. You configure three Prometheus alert rules (SLO burn rate critical, SLO burn rate warning, and dependency down), route alerts by severity to PagerDuty and Slack receivers, prove that grouping collapses multiple alerts into one notification, and demonstrate that inhibition suppresses symptom alerts when the root cause is active.

Built for the Pluralsight course: **Reliability, SLOs, and Incident Management for GenAI Systems** — Module 4 Clip 2.

---

## What You Will Learn

- Configure SLO burn rate alerts using the Google SRE fast-burn (14x) and slow-burn (2x) thresholds
- Add actionable annotations (runbook URL, owner, summary) so the on-call has everything they need in the alert itself
- Route alerts by severity — critical to PagerDuty, warning to Slack
- Group alerts by name and severity to prevent alert floods during multi-component outages
- Suppress symptom alerts using inhibition — when the dependency is down, the slow burn warning is noise
- Watch the complete alert lifecycle: INACTIVE → PENDING → FIRING → resolved

---

## Architecture

```
┌────────────────────────────────────────────────────────┐
│                  GenAI Service :8000                     │
│                                                         │
│   /ask pipeline                                         │
│   1. POST vector stub :8082 (retrieval)                │
│   2. POST model stub :8081 (inference)                 │
│   3. Return answer or 503                              │
│                                                         │
│   /metrics endpoint                                     │
│   genai_requests_total{status, endpoint}               │
│   genai_dependency_calls_total{dep, result}            │
│   genai_dependency_up{dep}                             │
└───────────────┬──────────────┬─────────────────────────┘
                │              │
       ┌────────┘              └────────┐
       ▼                                ▼
┌──────────────┐                ┌──────────────┐
│ Model Stub   │                │ Vector Stub  │
│ :8081        │                │ :8082        │
│ modes:       │                │ modes:       │
│  healthy     │                │  healthy     │
│  error       │                │  error       │
└──────────────┘                └──────────────┘

Prometheus :9090  ──scrapes──▶  App :8000/metrics
     │                              │
     │  evaluates 3 alert rules     │
     ▼                              │
Alertmanager :9093                  │
     │                              │
     │  routes by severity          │
     │  groups by alertname         │
     │  inhibits warning when       │
     │  dependency down is active   │
     ▼                              │
Webhook Stub :5001                  │
     │                              │
     │  /webhook/pagerduty          │
     │  /webhook/slack              │
     │  prints alert payload        │
     │  with ANSI colors            │
     │                              │
Grafana :3000  ◀────────────────────┘
     │
     │  5 panels:
     │  Alert State Timeline
     │  Error Rate
     │  Dependency Health
     │  Burn Rate
     │  Dependency Call Results
```

**Not used in this demo:** Redis, Toxiproxy, Tempo. This clip is purely alerting infrastructure.

---

## Prerequisites

- macOS 14+ or Linux
- Docker Desktop with `docker compose`
- Python 3.9+
- `tmux` installed (`brew install tmux` on macOS)
- Ports available: 3000, 5001, 8000, 8081, 8082, 9090, 9093

---

## Quick Start

```bash
# Start everything
bash scripts/demo_up.sh

# Verify all services healthy
bash scripts/preflight_check.sh    # 12/12 must pass

# Teardown
bash scripts/demo_down.sh
```

`demo_up.sh` starts Prometheus, Alertmanager, Grafana (via Docker), model stub, vector stub, webhook stub, and the GenAI app (via Python). A tmux session opens with T1 (alert receiver logs) and T2 (demo commands).

---

## Alert Rules Explained

Three rules in `infra/prometheus/rules.yml`:

### Rule 1: SLOBurnRateCritical

```
(error rate / total rate) > 14 × 0.001
severity: critical
for: 15s
```

**What it means:** The error budget is burning 14 times faster than the baseline allows. At this rate, a 99.9% monthly SLO exhausts its budget in about 5 hours. This is a right-now problem, not a tomorrow problem.

**Google SRE reference:** Chapter 6 defines 14.4x over 1 hour as the fast-burn threshold. The demo uses a 1-minute window so it fires within 30 seconds on camera. Production uses a 1-hour window with a 5-minute hold.

### Rule 2: SLOBurnRateWarning

```
(error rate / total rate) > 2 × 0.001
severity: warning
for: 15s
```

**What it means:** The error budget is burning 2 times faster than baseline. This catches gradual quality drift — the kind of degradation GenAI systems are prone to where the model starts returning slightly worse answers but the error rate barely moves.

**Why this rule exists:** Inhibition requires two severity levels to work. When DependencyDown fires as critical, this warning-level rule gets suppressed. Without it, inhibition has nothing to suppress.

### Rule 3: DependencyDown

```
rate(success calls)[30s] == 0  AND on(dep)  sum by(dep)(rate(all calls)[30s]) > 0
severity: critical
for: 10s
```

**What it means:** The dependency is receiving traffic but returning zero successful responses. The `and on(dep) sum by(dep)` clause is critical — it matches only on the `dep` label and sums across all `result` values. Without it, the `result="success"` label on both sides causes the `> 0` condition to always fail.

**Why `> 0` matters:** Without the second clause, a dependency that receives zero traffic looks dead. You page your on-call for nothing.

### Annotations (all three rules)

Every rule carries three annotations:

- `runbook_url` — direct link to the investigation playbook
- `owner` — which team is responsible
- `summary` — one-sentence description of the problem

In production, these three fields eliminate the first five minutes of every incident where the on-call asks "what is happening" and "who owns this."

---

## Alertmanager Config Explained

File: `infra/alertmanager/alertmanager.yml`

### Routing Tree

```
severity: critical  →  pagerduty-critical receiver  (wakes someone up)
severity: warning   →  slack-warning receiver        (reviewed during business hours)
```

### Grouping

```yaml
group_by: [alertname, severity]
```

Alerts with the same name and severity collapse into one notification. Without grouping, a 5-component outage sends 5 separate pages.

### Inhibition

```yaml
inhibit_rules:
  - source_match:
      alertname: DependencyDown
      severity: critical
    target_match:
      alertname: SLOBurnRateWarning
      severity: warning
```

When DependencyDown fires (root cause), SLOBurnRateWarning is suppressed (symptom). The critical burn rate alert stays because the on-call needs it. The warning is noise during a major incident.

### Demo vs Production Timers

| Setting                      | Demo | Production | Why different                         |
| ---------------------------- | ---- | ---------- | ------------------------------------- |
| `resolve_timeout`            | 30s  | 5m         | Alerts clear on camera after recovery |
| `group_wait`                 | 10s  | 30s        | First notification arrives faster     |
| `group_interval`             | 15s  | 5m         | Updates arrive faster                 |
| `repeat_interval` (critical) | 1m   | 4h         | Re-notification visible on camera     |
| `repeat_interval` (warning)  | 2m   | 12h        | Same                                  |
| Burn rate `rate()` window    | 1m   | 1h / 6h    | Fires within 30 seconds               |
| DependencyDown window        | 30s  | 5m         | Fires within 40 seconds               |
| `for` on burn rate rules     | 15s  | 5m         | PENDING → FIRING visible on camera    |
| `for` on DependencyDown      | 10s  | 2m         | Same                                  |

---

## Webhook Stub

File: `app/stubs/webhook.py`

A lightweight FastAPI server on port 5001 that simulates PagerDuty and Slack receivers. Every alert arrival is printed to stdout with ANSI color codes:

| Log element          | Color      |
| -------------------- | ---------- |
| `receiver=pagerduty` | Red bold   |
| `receiver=slack`     | Cyan bold  |
| `status=firing`      | Red bold   |
| `status=resolved`    | Green bold |
| `severity=critical`  | Red        |
| `severity=warning`   | Yellow     |

The `/divider/{label}` endpoint prints a cyan separator line between demo scenes.

---

## Step-by-Step Demo Walkthrough

### Step 1 — Start Everything

```bash
bash scripts/demo_down.sh
bash scripts/demo_up.sh
bash scripts/preflight_check.sh
```

**Expected output:** 12/12 passed, all [OK] lines visible.

**If preflight fails:**
- "Prometheus scraping app" fails → Wait 15 seconds and re-run. Prometheus needs 2–3 scrape cycles.
- "Alertmanager config loaded" fails → Check `infra/alertmanager/alertmanager.yml` for syntax errors. Run `docker logs clip2m4-alertmanager`.
- Any port busy → Run `bash scripts/demo_down.sh` and retry. If stuck: `lsof -ti tcp:<port> | xargs kill -9`.

### Step 2 — Verify Baseline

Open three browser tabs (hide tab bar during recording):

**Prometheus** — `localhost:9090/alerts`
- Expected: Inactive (3), Pending (0), Firing (0)
- All three rules green: DependencyDown, SLOBurnRateCritical, SLOBurnRateWarning
- Check "Show annotations" to see runbook_url, owner, summary

**Alertmanager** — `localhost:9093`
- Expected: "No alert groups found"

**Grafana** — `localhost:3000`
- Expected: Dashboard loads, Alert State Timeline shows all green

**Troubleshooting:**
- Grafana panels show "No data" → Check `infra/grafana/provisioning/datasources.yml` has `uid: prometheus`. Restart with `demo_down.sh` + `demo_up.sh`.
- Prometheus shows no rules → Check `infra/prometheus/prometheus.yml` has `rule_files: [/etc/prometheus/rules.yml]`. Run `docker logs clip2m4-prometheus`.

### Step 3 — View Alert Rules

In T2:
```bash
cat infra/prometheus/rules.yml
```

**What to look for:**
- `SLOBurnRateCritical` — `> (14 * 0.001)`, `severity: critical`, `for: 15s`
- `SLOBurnRateWarning` — `> (2 * 0.001)`, `severity: warning`, `for: 15s`
- `DependencyDown` — `== 0 and on(dep)`, `severity: critical`, `for: 10s`
- All three have `runbook_url`, `owner`, `summary` annotations

### Step 4 — Inject Errors and Watch Alerts Fire

```bash
bash scripts/scene_divider.sh "burn-rate-alert"
bash scripts/set_mode.sh model error
bash scripts/run_load.sh 45
```

**While load runs (status=503 scrolling in T2):**

1. Switch to `localhost:9090/alerts` — refresh every 10 seconds
   - At ~20 seconds: both burn rate rules show **PENDING** (orange badge)
   - At ~35 seconds: both show **FIRING** (red badge)
   - DependencyDown stays INACTIVE (vector stub is still healthy)
2. Expand SLOBurnRateCritical — verify labels and annotations visible
3. Switch to `localhost:9093` — verify routing:
   - `pagerduty-critical` group → SLOBurnRateCritical (1 alert)
   - `slack-warning` group → SLOBurnRateWarning (1 alert)

**After load finishes:**

4. Show Alertmanager config:
   ```bash
   cat infra/alertmanager/alertmanager.yml
   ```
5. Check T1 — receiver logs show:
   - `receiver=pagerduty  status=firing  alertname=SLOBurnRateCritical  severity=critical`
   - `receiver=slack  status=firing  alertname=SLOBurnRateWarning  severity=warning`
6. Wait ~30 seconds — alerts auto-resolve as rate window clears:
   - `receiver=pagerduty  status=resolved  alertname=SLOBurnRateCritical`
   - `receiver=slack  status=resolved  alertname=SLOBurnRateWarning`

**Troubleshooting:**
- Alerts never reach PENDING → Prometheus is not scraping. Check `localhost:9090/targets` — genai-service target should show UP.
- Alerts stuck in PENDING → The `for` timer has not elapsed. Wait 15 more seconds.
- No webhook logs in T1 → Webhook stub not running. Check `curl -s localhost:5001/health`. Restart with `demo_up.sh`.
- Alertmanager shows no groups → Prometheus alerting config not pointing to Alertmanager. Check `infra/prometheus/prometheus.yml` has `alertmanagers` section.

### Step 5 — Reset Before Dependency Test

```bash
bash scripts/scene_divider.sh "reset-before-dependency"
bash scripts/set_mode.sh model healthy
bash scripts/run_load.sh 45
```

Wait 60 seconds after load finishes.

**Expected:**
- `localhost:9090/alerts` → all 3 INACTIVE
- T2 shows `status=200` requests
- T1 shows resolved alerts (if not already resolved in Step 4)

**Troubleshooting:**
- Burn rate rules still FIRING after 60 seconds → The 1-minute rate window needs enough healthy traffic to dilute the error rate. Run `bash scripts/run_load.sh 30` again and wait.

### Step 6 — DependencyDown + Inhibition

```bash
bash scripts/scene_divider.sh "dependency-down-inhibition"
bash scripts/set_mode.sh model error
bash scripts/set_mode.sh vector error
bash scripts/run_load.sh 90 &
```

**Important:** The load runs in the background for 90 seconds. You must check Alertmanager WHILE IT IS RUNNING — DependencyDown uses a 30-second window and resolves quickly after traffic stops.

**While load runs (you have 90 seconds):**

1. Wait 30 seconds, then check `localhost:9090/alerts`:
   - DependencyDown: PENDING → **FIRING** (for `dep=vector_db`)
   - SLOBurnRateCritical: **FIRING**
   - SLOBurnRateWarning: **FIRING**
   - Prometheus shows all three because it evaluates rules independently and does not know about inhibition

2. Switch to `localhost:9093`:
   - Default view shows `pagerduty-critical` with DependencyDown + SLOBurnRateCritical
   - **SLOBurnRateWarning is MISSING** from the default view — it is suppressed
   - **Check the "Inhibited" checkbox** (top right, next to "Silenced")
   - SLOBurnRateWarning appears with "Inhibited" link/badge

3. Check T1 — receiver logs:
   - `receiver=pagerduty  status=firing  alertname=DependencyDown  severity=critical`
   - `receiver=pagerduty  status=firing  alertname=SLOBurnRateCritical  severity=critical`
   - **NO `receiver=slack  alertname=SLOBurnRateWarning` line** — inhibited, never delivered

4. Wait for background load to finish:
   ```bash
   wait
   ```

**Troubleshooting:**
- DependencyDown never fires → The `on(dep)` clause requires both `result="success"` and `result="error"` series to exist for the same `dep` label. Send at least 10 seconds of traffic after setting vector to error. If still not firing, check `localhost:9090/graph` and query `rate(genai_dependency_calls_total{dep="vector_db"}[30s])` — verify both success (0) and error (>0) series exist.
- SLOBurnRateWarning not showing as inhibited → DependencyDown must be in FIRING state (not just PENDING) for inhibition to activate. Wait for the `for: 10s` timer to complete.
- SLOBurnRateWarning shows in Alertmanager but not inhibited → DependencyDown resolved before you checked. The 30-second window clears fast. Re-run Step 6 and check the UI within 45 seconds of starting the load.

### Step 7 — Recovery

```bash
bash scripts/scene_divider.sh "recovery"
bash scripts/set_mode.sh model healthy
bash scripts/set_mode.sh vector healthy
bash scripts/run_load.sh 60
```

Wait 90 seconds after load finishes.

**Expected:**
- `localhost:9090/alerts` → Inactive (3), all green
- `localhost:9093` → "No alert groups found"
- T1 → green `status=resolved` lines for DependencyDown and SLOBurnRateCritical

**Troubleshooting:**
- Alerts still FIRING after 90 seconds → Rate windows still contain error data. Run another `bash scripts/run_load.sh 30` with healthy stubs.

### Step 8 — Grafana Dashboard

Open `localhost:3000`. Set time range to **Last 15 minutes**.

**Expected panels:**

| Panel                   | Expected                                                                                              |
| ----------------------- | ----------------------------------------------------------------------------------------------------- |
| Alert State Timeline    | Green → red → green bands for each rule. Two red phases visible (Step 4 burn rate + Step 6 all three) |
| Error Rate              | Red spike(s) during error injection, drops to zero after recovery. Green success line returns         |
| Dependency Health       | Both model_api and vector_db show **UP** in green                                                     |
| Burn Rate               | Orange line at ~1000 during outage, flat at zero after recovery                                       |
| Dependency Call Results | model_api errors spike first (Step 4), vector_db errors join (Step 6), both return to success         |

**Troubleshooting:**
- Alert State Timeline shows only red, no green → The `or vector(0)` fallback should show green during inactive periods. If not, check `grafana/dashboards/dashboard.json` has the `or vector(0)` queries.
- Panels show "No data" → Datasource UID mismatch. Check `infra/grafana/provisioning/datasources.yml` has `uid: prometheus`.

---

## Project Structure

```
├── app/
│   ├── main.py                    # GenAI service with /ask, /metrics, /health
│   └── stubs/
│       ├── model.py               # Model API stub (healthy/error modes)
│       ├── vector.py              # Vector DB stub (healthy/error modes)
│       └── webhook.py             # Alert receiver stub with ANSI colors
├── scripts/
│   ├── demo_up.sh                 # Start everything + tmux session
│   ├── demo_down.sh               # Stop everything
│   ├── preflight_check.sh         # 12-point health check
│   ├── set_mode.sh                # Switch stubs: model/vector × healthy/error
│   ├── run_load.sh                # Send traffic for N seconds
│   └── scene_divider.sh           # Print visual separator in webhook logs
├── infra/
│   ├── docker-compose.yaml        # Prometheus, Alertmanager, Grafana
│   ├── prometheus/
│   │   ├── prometheus.yml         # Scrape config + alertmanager target
│   │   └── rules.yml              # 3 alert rules
│   ├── alertmanager/
│   │   └── alertmanager.yml       # Routing, grouping, inhibition
│   └── grafana/
│       ├── dashboards/
│       │   └── dashboard.json     # 5 panels
│       └── provisioning/
│           ├── datasources.yml    # uid: prometheus
│           └── dashboards.yml     # Dashboard provisioning
├── grafana/dashboards/
│   └── dashboard.json             # Dashboard (alternate mount path)
├── requirements.txt
├── DEMO-STEPS.md                  # Recording choreography
└── README.md                      # This file
```

---

## Key Design Decisions

**Three rules, not one.** Most alerting tutorials show a single error rate threshold. Production needs three: fast burn (critical, wake someone up), slow burn (warning, review during business hours), and dependency down (critical, root cause). Three rules enable severity routing and inhibition — neither works with just one rule.

**Webhook stub over real API keys.** The demo uses a local HTTP server that prints alert payloads with color codes. No PagerDuty or Slack API keys needed. The viewer sees the alert arrive at the receiver in real time — not a hand-wave about what "would happen."

**Burn rate over raw error rate.** A raw error rate threshold (e.g., error rate > 5%) fires too late or too often. Burn rate measures how fast the error budget is being consumed relative to the baseline. Google SRE Chapter 6 established the 14x fast-burn and 2x slow-burn thresholds that predict budget exhaustion timing.

**`on(dep)` in DependencyDown.** The PromQL `and` operator matches on ALL labels by default. The left side has `result="success"` with rate 0. Without `on(dep)`, the right side also matches `result="success"` which is also 0 — so `> 0` always fails. The `on(dep)` clause restricts matching to the `dep` label only, and `sum by(dep)` on the right side combines success+error rates.

**Demo-shortened timers.** Every timer (rate windows, `for` durations, resolve timeout, repeat interval) is shortened for camera visibility. The README and alert rule comments document the production values. Narration calls out every difference explicitly.

---

## Tech Stack

| Component        | Version        | Purpose                                    |
| ---------------- | -------------- | ------------------------------------------ |
| Python / FastAPI | 3.9+ / 0.111.0 | GenAI service + stubs                      |
| Prometheus       | 2.54.1         | Metrics collection + alert rule evaluation |
| Alertmanager     | 0.27.0         | Alert routing, grouping, inhibition        |
| Grafana          | 11.1.4         | Dashboard visualization                    |

---

## Learning Objectives Covered

| LO  | Description                | Proof                                               |
| --- | -------------------------- | --------------------------------------------------- |
| 4b  | Alert on SLO burn rate     | SLOBurnRateCritical FIRING with 14x threshold       |
| 4b  | Alert on dependency health | DependencyDown FIRING for vector_db                 |
| 4b  | Actionable context         | runbook_url, owner, summary visible in alert detail |
| 4b  | Severity levels + routing  | Critical → PagerDuty, Warning → Slack               |
| 4b  | Escalation policies        | Alertmanager routing tree on screen                 |
| 4b  | Grouping                   | group_by config + grouped notification              |
| 4b  | Inhibition                 | Inhibited badge + zero Slack delivery               |

---

## Common Issues and Fixes

| Issue                                          | Cause                                            | Fix                                                                                    |
| ---------------------------------------------- | ------------------------------------------------ | -------------------------------------------------------------------------------------- |
| Preflight shows "Prometheus scraping app" FAIL | Prometheus needs 2-3 scrape cycles after startup | Wait 15 seconds, re-run preflight                                                      |
| Grafana panels show "No data"                  | Datasource UID mismatch                          | Verify `uid: prometheus` in `datasources.yml`, restart                                 |
| DependencyDown never fires                     | `on(dep)` missing or both stubs set to same mode | Verify `rules.yml` has `and on(dep)`, set BOTH model and vector to error               |
| Alerts never reach PENDING                     | Prometheus not scraping app metrics              | Check `localhost:9090/targets` — genai-service should show UP                          |
| Alerts stuck in PENDING                        | `for` timer not elapsed                          | Wait 15 seconds for burn rate, 10 seconds for DependencyDown                           |
| Inhibition not visible                         | DependencyDown resolved before checking          | Re-run with `run_load.sh 90 &` and check UI within 45 seconds                          |
| Alerts never resolve after recovery            | Rate window still contains error data            | Send more healthy traffic: `run_load.sh 60`                                            |
| Webhook logs not showing                       | Webhook stub crashed                             | Check `curl -s localhost:5001/health`, restart with `demo_up.sh`                       |
| Docker containers not starting                 | Ports busy from previous run                     | Run `demo_down.sh` first. If stuck: `docker ps -a` and `docker rm -f` stale containers |
| tmux green status bar visible                  | `status off` not applied                         | Run `tmux set -g status off` inside the session                                        |

---

## License

MIT