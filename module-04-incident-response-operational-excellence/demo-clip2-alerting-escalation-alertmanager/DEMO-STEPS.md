# Demo: M4-C2

## Demo: Alerting and Escalation with Prometheus Alertmanager

---

## Clip Summary

- **Duration:** 5 minutes (644 words)
- **LO:** 4b only
- **Outline bullets:**
  1. Alert on SLO burn rate and critical dependency health
  2. Add actionable context: runbook links, ownership, and severity
  3. Route and escalate alerts based on severity policies
  4. Configure grouping and inhibition to prevent alert floods

---

## Stack

```
App :8000            FastAPI — /metrics exposes burn rate + dependency health
Prometheus :9090     Scrapes app, evaluates 3 alert rules
Alertmanager :9093   Routes by severity, groups alerts, inhibits symptom alerts
Webhook Stub :5001   Prints received alerts — simulates PagerDuty/Slack receivers
Grafana :3000        Alert state timeline panel
```

**NOT used:** Redis, Toxiproxy, Tempo. This clip is purely alerting infrastructure.

---

## Alert Rules (3 rules, not 2)

### Rule 1: SLOBurnRateCritical

```yaml
- alert: SLOBurnRateCritical
  expr: |
    (
      rate(genai_requests_total{status="error"}[5m])
      /
      rate(genai_requests_total[5m])
    ) > (14 * 0.001)
  for: 30s
  labels:
    severity: critical
  annotations:
    summary: "Error budget burning 14x faster than baseline"
    runbook_url: "https://runbooks.internal/genai/slo-burn-rate"
    owner: "platform-team"
```

**Why 14x:** Google SRE Chapter 6 defines 14.4x over 1h as "fast burn" — predicts budget exhaustion within hours. Demo uses 5m window + 30s `for` so it fires on camera. Production uses 1h window + 5m `for`.

**Why `for: 30s`:** Production uses `for: 5m` to avoid flapping. Demo shortens to 30s so PENDING → FIRING lifecycle is visible within the 5-minute clip. Narrate the difference.

### Rule 2: SLOBurnRateWarning

```yaml
- alert: SLOBurnRateWarning
  expr: |
    (
      rate(genai_requests_total{status="error"}[5m])
      /
      rate(genai_requests_total[5m])
    ) > (2 * 0.001)
  for: 30s
  labels:
    severity: warning
  annotations:
    summary: "Error budget burning 2x faster than baseline — slow burn"
    runbook_url: "https://runbooks.internal/genai/slo-burn-rate"
    owner: "platform-team"
```

**Why this rule exists:** Inhibition requires two severity levels. When DependencyDown fires as critical, it suppresses this warning-level rule. Without it, inhibition has nothing to suppress.

**Why 2x:** Google SRE slow-burn threshold. Catches gradual degradation over hours — the kind of quality drift GenAI systems are prone to.

### Rule 3: DependencyDown

```yaml
- alert: DependencyDown
  expr: |
    rate(genai_dependency_calls_total{result="success"}[2m]) == 0
    and
    rate(genai_dependency_calls_total[2m]) > 0
  for: 30s
  labels:
    severity: critical
  annotations:
    summary: "{{ $labels.dep }} has returned zero successful responses for 2 minutes"
    runbook_url: "https://runbooks.internal/genai/dependency-down"
    owner: "platform-team"
```

**Why `and rate > 0`:** Without it, a dependency with zero traffic looks "down." The second clause ensures the dependency is receiving calls and failing all of them.

---

## Alertmanager Config

```yaml
global:
  resolve_timeout: 1m  # Demo: 1m so alerts clear on camera. Production: 5m.

route:
  receiver: default
  group_by: [alertname, severity]
  group_wait: 15s
  group_interval: 30s
  repeat_interval: 1m  # Demo: 1m. Production: 4h critical, 12h warning.
  routes:
    - match:
        severity: critical
      receiver: pagerduty-critical
      repeat_interval: 1m
    - match:
        severity: warning
      receiver: slack-warning
      repeat_interval: 2m

receivers:
  - name: default
    webhook_configs:
      - url: http://host.docker.internal:5001/webhook/default
  - name: pagerduty-critical
    webhook_configs:
      - url: http://host.docker.internal:5001/webhook/pagerduty
  - name: slack-warning
    webhook_configs:
      - url: http://host.docker.internal:5001/webhook/slack

inhibit_rules:
  - source_match:
      alertname: DependencyDown
      severity: critical
    target_match:
      alertname: SLOBurnRateWarning
      severity: warning
    equal: []
```

### Key Config Decisions

**`resolve_timeout: 1m`** — Production uses 5m. Demo uses 1m so Scene 5 recovery shows cleared alerts on camera within 60 seconds.

**`group_by: [alertname, severity]`** — Multiple alerts with the same name and severity collapse into one notification. Without grouping, a 5-dependency outage produces 5 simultaneous pages.

**Inhibition logic:** When DependencyDown (critical) fires, SLOBurnRateWarning (warning) is suppressed. The critical burn rate alert STAYS because the on-call needs it. The warning is noise during a major incident — it tells you the budget is burning slowly, but you already know the dependency is down. Suppressing the symptom, keeping the root cause.

**Webhook stubs** — `host.docker.internal:5001` points to a local Python stub that prints alert payloads to stdout. No real PagerDuty/Slack API keys needed. The viewer sees the alert arrive at the "receiver" in real-time.

---

## App Metrics (exposed on /metrics)

```
genai_requests_total{status="success|error", endpoint="/ask"}
genai_dependency_calls_total{dep="model_api|vector_db", result="success|error"}
genai_dependency_up{dep="model_api|vector_db"}  # gauge 0 or 1
```

The app has `set_mode.sh` to switch stubs between healthy/error modes (same pattern as Clip 2 M3).

---

## Webhook Stub (15-line Python)

```python
from fastapi import FastAPI, Request
import json, logging

app = FastAPI()
log = logging.getLogger("webhook-stub")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S")

@app.post("/webhook/{receiver}")
async def receive(receiver: str, request: Request):
    body = await request.json()
    alerts = body.get("alerts", [])
    for a in alerts:
        log.info("ALERT  receiver=%s  status=%s  alertname=%s  severity=%s",
                 receiver, a["status"], a["labels"].get("alertname"), a["labels"].get("severity"))
    return {"status": "ok"}
```

Runs on port 5001. Prints each alert arrival to stdout. During Scene 4, the viewer sees "pagerduty" receiver getting the critical alert while "slack" does NOT get the suppressed warning.

---

## Grafana Dashboard (3 panels)

| Panel | Type | Query |
|-------|------|-------|
| Alert State Timeline | State timeline | `ALERTS{alertname=~"SLO.*\|Dependency.*"}` |
| Error Rate | Time series | `rate(genai_requests_total{status="error"}[1m])` |
| Dependency Health | Stat | `genai_dependency_up` per dep — green 1 / red 0 |

---

## Before Recording

```bash
bash scripts/demo_down.sh
bash scripts/demo_up.sh
bash scripts/preflight_check.sh    # all services healthy
```

Open `localhost:9090/alerts` — confirm all 3 rules show INACTIVE.
Open `localhost:9093` — confirm Alertmanager shows no active alerts.
Open `localhost:3000` — confirm dashboard loads, all panels have data or show "OK" state.

Then restart for clean state:

```bash
bash scripts/demo_down.sh
bash scripts/demo_up.sh
```

---

### Hit Record

---

### SCENE 0 — Stack Up (0:00–0:15)

Run `demo_up.sh` live. Point to:

```
[OK] App :8000
[OK] Prometheus :9090
[OK] Alertmanager :9093
[OK] Webhook stub :5001
[OK] Grafana :3000
```

---

### SCENE 1 — Alert Rules: What Fires and Why (0:15–1:10)

**LO 4b — alert on SLO burn rate and dependency health, actionable context**

Type in T2:

```bash
cat infra/prometheus/rules.yml
```

Point to three rules:

**SLOBurnRateCritical:**
- Point to the expression: error rate divided by total rate, threshold 14 times the error budget
- Point to `for: 30s` — explain: "In production this is 5 minutes. I use 30 seconds so you see the full lifecycle on camera."
- Point to `severity: critical`

**SLOBurnRateWarning:**
- Point to 2x threshold — slow burn catches gradual drift
- Point to `severity: warning`

**DependencyDown:**
- Point to `rate(success) == 0 and rate(total) > 0` — explain: "The second clause prevents a quiet dependency from looking dead."
- Point to `severity: critical`

**Annotations (all three rules):**
- Point to `runbook_url`, `owner`, `summary`
- "These are the fields your on-call engineer reads first when paged."

Open Prometheus alerts page:

```bash
# Browser: localhost:9090/alerts
```

Point to all 3 rules showing state **INACTIVE**.

---

### SCENE 2 — SLO Burn Rate Alert Fires (1:10–2:20)

**LO 4b — alert on SLO burn rate**

Inject errors to burn the error budget:

```bash
bash scripts/set_mode.sh model error
bash scripts/run_load.sh 60
```

**While load runs, narrate what is happening.** The app returns errors on every request. The error rate spikes. The burn rate expression crosses the 14x threshold.

After ~30 seconds, refresh Prometheus alerts page. Point to:

- **SLOBurnRateCritical:** INACTIVE → **PENDING**
- "The `for` timer started. Prometheus waits 30 seconds to confirm this is not a blip."

After another ~30 seconds:

- **SLOBurnRateCritical:** PENDING → **FIRING**
- **SLOBurnRateWarning:** also **FIRING** (2x threshold crossed too)

Point to the alert detail — expand one rule:

- `severity: critical`
- `runbook_url: https://runbooks.internal/genai/slo-burn-rate`
- `owner: platform-team`
- `summary: Error budget burning 14x faster than baseline`

"Every field the on-call needs is in the alert. No Slack thread required to find the runbook."

Check Alertmanager API:

```bash
curl -s localhost:9093/api/v2/alerts | python3 -m json.tool
```

Point to both alerts visible with full labels and annotations.

---

### SCENE 3 — Alertmanager Routing and Escalation (2:20–3:20)

**LO 4b — route and escalate by severity**

Show Alertmanager config:

```bash
cat infra/alertmanager/alertmanager.yml
```

Point to:

- **Routing tree:** `severity: critical` → `pagerduty-critical` receiver. `severity: warning` → `slack-warning` receiver.
- **`group_by: [alertname, severity]`** — "Alerts with the same name and severity collapse into one notification. Without this, a multi-component outage sends 5 pages."
- **`repeat_interval`** — "Critical repeats every 4 hours in production. Warning repeats every 12 hours."

Open Alertmanager UI:

```bash
# Browser: localhost:9093
```

Point to active alerts, routed to correct receivers.

**Switch to webhook stub terminal.** Point to the stdout log:

```
ALERT  receiver=pagerduty  status=firing  alertname=SLOBurnRateCritical  severity=critical
ALERT  receiver=slack       status=firing  alertname=SLOBurnRateWarning   severity=warning
```

"The critical alert went to PagerDuty. The warning went to Slack. Same incident, different urgency channels."

---

### SCENE 4 — Grouping and Inhibition (3:20–4:30)

**LO 4b — grouping to prevent alert floods, inhibition**

Inject dependency failure — model API goes fully down:

```bash
bash scripts/set_mode.sh vector error
```

Now DependencyDown fires for vector_db. Wait ~45 seconds for FIRING state.

**Open Alertmanager UI.** Three alerts firing — but point to:

- **Grouping:** SLOBurnRateCritical and SLOBurnRateWarning grouped into one notification block, not two separate pages.
- "Your on-call got one page, not three."

**Show inhibition:**

Point to SLOBurnRateWarning — status shows **suppressed** or **inhibited**.

Show the inhibition rule:

```bash
grep -A8 "inhibit_rules" infra/alertmanager/alertmanager.yml
```

Point to: "When DependencyDown fires as critical, SLOBurnRateWarning is suppressed. The root cause silences the symptom."

**Switch to webhook stub terminal.** Point to:

```
ALERT  receiver=pagerduty  status=firing  alertname=DependencyDown       severity=critical
ALERT  receiver=pagerduty  status=firing  alertname=SLOBurnRateCritical  severity=critical
```

**No `SLOBurnRateWarning` alert at the pagerduty or slack receiver.** It was inhibited. On-call sees root cause + critical burn, not the noise.

---

### SCENE 5 — Recovery and Resolve (4:30–5:00)

**LO 4b — full alert lifecycle**

Recover both dependencies:

```bash
bash scripts/set_mode.sh model healthy
bash scripts/set_mode.sh vector healthy
```

Send a few healthy requests to flush the rate window:

```bash
bash scripts/run_load.sh 15
```

Watch Prometheus alerts page:

- All three rules: FIRING → **INACTIVE**

Watch Alertmanager UI:

- Active alerts clear

Watch webhook stub:

```
ALERT  receiver=pagerduty  status=resolved  alertname=SLOBurnRateCritical  severity=critical
ALERT  receiver=pagerduty  status=resolved  alertname=DependencyDown       severity=critical
```

"Every alert that fired also resolved. Your on-call sees the clear notification. The incident lifecycle is complete."

Open Grafana dashboard. Point to Alert State Timeline panel showing the full lifecycle:

- Green (INACTIVE) → Yellow (PENDING) → Red (FIRING) → Green (INACTIVE)

"That is the complete lifecycle of a production alert — from first detection through escalation to resolution."

---

### Stop Recording

```bash
bash scripts/demo_down.sh
```

---

## Post-Recording Checklist

- [ ] Scene 1: All 3 rules visible with annotations (runbook_url, owner, severity)
- [ ] Scene 1: Prometheus /alerts shows all 3 rules as INACTIVE
- [ ] Scene 2: SLOBurnRateCritical transitioned INACTIVE → PENDING → FIRING
- [ ] Scene 2: Alert detail shows severity, runbook_url, owner on screen
- [ ] Scene 2: Alertmanager API returns alerts with full labels
- [ ] Scene 3: Alertmanager config shows routing tree by severity
- [ ] Scene 3: Webhook stub shows critical → pagerduty, warning → slack
- [ ] Scene 3: group_by visible in config
- [ ] Scene 4: DependencyDown fires alongside burn rate alerts
- [ ] Scene 4: SLOBurnRateWarning shows inhibited/suppressed in Alertmanager UI
- [ ] Scene 4: Webhook stub shows NO SLOBurnRateWarning delivery
- [ ] Scene 5: All alerts transition to INACTIVE / resolved
- [ ] Scene 5: Webhook stub shows resolved status
- [ ] Scene 5: Grafana alert state timeline shows full lifecycle
- [ ] No browser tabs visible except Prometheus / Alertmanager / Grafana

---

## LO Coverage

| LO 4b Requirement | Scene | Proof |
|---|---|---|
| Alert on SLO burn rate | 2 | SLOBurnRateCritical fires, 14x threshold on screen |
| Alert on dependency health | 4 | DependencyDown fires for vector_db |
| Actionable context | 1, 2 | runbook_url, owner, summary visible in rule + alert detail |
| Severity levels | 1, 2, 3 | critical and warning labels route to different receivers |
| Escalation policies | 3 | Routing tree sends critical → pagerduty, warning → slack |
| Grouping | 3, 4 | group_by config + grouped notification in Alertmanager UI |
| Inhibition | 4 | DependencyDown suppresses SLOBurnRateWarning, webhook proof |

---

## Duplication Check

| Concept | Prior clips | Clip 2 M4 |
|---|---|---|
| SLO error budget | M2 dashboards concept | Burn rate RULE — new layer ✅ |
| Incident lifecycle | Clip 1 M4 — fully taught | Not mentioned ✅ |
| On-call roles | Clip 1 M4 — fully taught | Not mentioned ✅ |
| Prometheus metrics | M3 demos — scraping only | Alert RULES are new ✅ |
| Grafana panels | M3 demos — metric panels | Alert STATE panel is new ✅ |
| Alertmanager | Never appeared | Introduced fresh ✅ |
| Inhibition | Never appeared | Introduced fresh ✅ |
| Grouping | Never appeared | Introduced fresh ✅ |
| Runbook annotations | Never appeared | Introduced fresh ✅ |
| Webhook receivers | Never appeared | Introduced fresh ✅ |

Zero duplication.

---

## Demo vs Production Settings

| Setting | Demo value | Production value | Why different |
|---|---|---|---|
| `for` on alert rules | 30s | 5m | Lifecycle visible on camera |
| `resolve_timeout` | 1m | 5m | Recovery visible on camera |
| `repeat_interval` critical | 1m | 4h | Re-notification visible on camera |
| `repeat_interval` warning | 2m | 12h | Same |
| Burn rate window | `rate()[5m]` | `rate()[1h]` and `rate()[6h]` | Fires within 60s of error injection |
| Receivers | Webhook stub :5001 | PagerDuty API + Slack webhook | No API keys needed for demo |

**Narrate every difference.** "In production you use X. I use Y here so the lifecycle is visible on camera."

---

## What Makes This Bar-Raiser

**Burn rate over raw error rate:** Most alerting tutorials fire on `error_rate > 5%`. Burn rate alerts on how fast the error budget is being consumed — predicting budget exhaustion hours in advance. Google SRE Chapter 6 defines the 14x fast-burn and 2x slow-burn thresholds.

**Three rules, not one:** Fast burn (critical), slow burn (warning), dependency down (critical). Three rules because production needs three different response urgencies. Most courses show one rule.

**Inhibition with working proof:** The viewer sees the webhook stub NOT receiving the suppressed alert. That is the proof most courses skip — they show the inhibit config but never prove the alert was actually suppressed.

**Webhook stub as receiver proof:** Instead of hand-waving "this would go to PagerDuty," the viewer sees the alert payload arrive at a real HTTP endpoint in real-time. The receiver is not theoretical.

**Full lifecycle on camera:** INACTIVE → PENDING → FIRING → resolved. Most demos show firing but never recovery. Scene 5 proves the system heals.

**Actionable annotations:** Every alert carries runbook_url, owner, summary. Clip 1 taught that roles matter during incidents. This clip proves the alert itself delivers the context those roles need.

---

## Code to Build

| Component | File | Description |
|---|---|---|
| App | `app/main.py` | FastAPI with /metrics, /health, set_mode support |
| Model stub | `app/stubs/model.py` | Same pattern as M3 clips |
| Vector stub | `app/stubs/vector.py` | Same pattern as M3 clips |
| Webhook stub | `app/stubs/webhook.py` | 15-line FastAPI that prints alerts |
| Alert rules | `infra/prometheus/rules.yml` | 3 rules: BurnCritical, BurnWarning, DepDown |
| Prometheus config | `infra/prometheus/prometheus.yml` | Scrape app:8000, rule_files |
| Alertmanager config | `infra/alertmanager/alertmanager.yml` | Routes, grouping, inhibition |
| Grafana dashboard | `grafana/dashboards/dashboard.json` | 3 panels: state timeline, error rate, dep health |
| Grafana datasources | `infra/grafana/provisioning/datasources.yml` | uid: prometheus (learned from M3 clip 4 bug) |
| docker-compose | `infra/docker-compose.yaml` | Prometheus, Alertmanager, Grafana, webhook stub |
| demo_up.sh | `scripts/demo_up.sh` | Start all, tmux T1/T2, status off |
| demo_down.sh | `scripts/demo_down.sh` | Kill all, same pattern as M3 |
| set_mode.sh | `scripts/set_mode.sh` | Switch stubs healthy/error |
| run_load.sh | `scripts/run_load.sh` | Send N seconds of traffic |
| preflight_check.sh | `scripts/preflight_check.sh` | Verify all endpoints |

---

## Confirm Before Building

1. **Webhook stubs over real API keys** — PagerDuty and Slack receivers use a local webhook stub on :5001 that prints alert payloads. No API keys needed. Viewer sees the alert arrive in real-time. Confirm this approach.

2. **Three rules (critical burn + warning burn + dependency down)** — required for inhibition to work correctly. Inhibition suppresses the warning burn when dependency down fires. Confirm this structure.

3. **Demo-shortened timers** — `for: 30s`, `resolve_timeout: 1m`, `rate()[5m]`. All called out in narration as "production uses X, demo uses Y." Confirm acceptable.

4. **Grafana datasource uid: prometheus** — learned from M3 Clip 4 bug. Provisioned explicitly. Confirm.

5. **Alert State Timeline panel in Grafana** — shows INACTIVE → PENDING → FIRING → INACTIVE lifecycle. Confirm this is the panel type you want for Scene 5.
