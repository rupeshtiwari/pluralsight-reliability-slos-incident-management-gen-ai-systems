"""
Incident Metrics Exporter — Operational Excellence Demo

Reads structured postmortem YAML files and exposes Prometheus metrics:
  - incident_total          (gauge by severity, root_cause_category)
  - incident_mttr_seconds   (gauge by incident id)
  - operational_toil_hours  (gauge by toil_category)
  - repeat_incident_total   (gauge by root_cause_category — count of incidents per family)
  - action_item_total       (gauge by status — open vs closed)
  - incident_mttr_average_seconds (gauge, no labels)

The exporter re-reads YAML files on every /metrics scrape so Grafana
always reflects the latest postmortem state without restart.

Fix note (2026-03-19):
  prometheus_client 0.20.0 only creates the _metrics dict on "parent"
  metrics (those with labelnames).  Calling ._metrics.clear() on a
  label-less gauge like MTTR_AVERAGE crashes with AttributeError.
  Fixed by building a fresh CollectorRegistry per scrape — no clearing
  needed, no stale label combinations, no internal-API dependency.
"""

import glob
import logging
import os
from datetime import datetime
from typing import Optional

import yaml
from fastapi import FastAPI
from prometheus_client import (
    CollectorRegistry,
    Gauge,
    generate_latest,
)
from starlette.responses import Response

# ---------------------------------------------------------------------------
# Logging — force=True required because uvicorn configures root logger
# before importing the app, making basicConfig a no-op without it.
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-5s  %(message)s",
    datefmt="%H:%M:%S",
    force=True,
)
log = logging.getLogger("incident-exporter")
log.setLevel(logging.INFO)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
POSTMORTEM_DIR = os.getenv(
    "POSTMORTEM_DIR",
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "postmortems"),
)

# ---------------------------------------------------------------------------
# Controlled enum values — must match schema.yaml
# ---------------------------------------------------------------------------
VALID_SEVERITIES = {"SEV1", "SEV2", "SEV3"}
VALID_ROOT_CAUSE_CATEGORIES = {
    "retrieval_cascade", "model_timeout", "alert_noise",
    "manual_recovery", "deploy_regression",
}
VALID_TOIL_CATEGORIES = {
    "cascading_failure_recovery", "alert_noise_triage",
    "manual_scaling", "manual_deploy", "manual_postmortem",
}


# ---------------------------------------------------------------------------
# YAML reader with validation
# ---------------------------------------------------------------------------
def _parse_datetime(dt_str):
    # type: (str) -> Optional[datetime]
    """Parse ISO datetime string."""
    try:
        # Handle Z suffix
        if dt_str.endswith("Z"):
            dt_str = dt_str[:-1] + "+00:00"
        # Python 3.9 compatible parsing
        return datetime.fromisoformat(dt_str)
    except (ValueError, AttributeError):
        return None


def _load_postmortems():
    """Load and validate all postmortem YAML files."""
    pattern = os.path.join(POSTMORTEM_DIR, "INC-*.yaml")
    files = sorted(glob.glob(pattern))
    postmortems = []
    for fpath in files:
        try:
            with open(fpath, "r") as f:
                data = yaml.safe_load(f)
            if not data or not isinstance(data, dict):
                log.warning("Skipping empty file: %s", fpath)
                continue

            # Validate controlled fields
            sev = data.get("severity", "")
            rcc = data.get("root_cause_category", "")
            if sev not in VALID_SEVERITIES:
                log.warning("Invalid severity '%s' in %s — skipping", sev, fpath)
                continue
            if rcc not in VALID_ROOT_CAUSE_CATEGORIES:
                log.warning("Invalid root_cause_category '%s' in %s — skipping", rcc, fpath)
                continue

            postmortems.append(data)
        except Exception as e:
            log.error("Failed to load %s: %s", fpath, e)
    return postmortems


# ---------------------------------------------------------------------------
# Build a fresh registry on every scrape
# ---------------------------------------------------------------------------
def _build_metrics():
    """Re-read all postmortems, build a fresh registry, return it.

    A fresh CollectorRegistry on every scrape avoids the need to clear
    stale label combinations.  The ._metrics internal dict does not exist
    on label-less gauges in prometheus_client 0.20.0, so creating a new
    registry is the safest, version-portable approach.
    """
    postmortems = _load_postmortems()

    registry = CollectorRegistry()

    incident_total = Gauge(
        "incident_total",
        "Total incidents by severity and root cause category",
        labelnames=["severity", "root_cause_category"],
        registry=registry,
    )
    incident_mttr = Gauge(
        "incident_mttr_seconds",
        "Mean time to recovery in seconds per incident",
        labelnames=["incident_id", "severity", "root_cause_category"],
        registry=registry,
    )
    toil_hours = Gauge(
        "operational_toil_hours",
        "Hours of operational toil by category",
        labelnames=["toil_category"],
        registry=registry,
    )
    repeat_incident = Gauge(
        "repeat_incident_total",
        "Number of incidents per root cause category (repeat detection)",
        labelnames=["root_cause_category"],
        registry=registry,
    )
    action_item_total = Gauge(
        "action_item_total",
        "Action items by status",
        labelnames=["status"],
        registry=registry,
    )
    mttr_average = Gauge(
        "incident_mttr_average_seconds",
        "Average MTTR across all incidents",
        labelnames=[],
        registry=registry,
    )

    # Accumulators
    category_counts = {}   # root_cause_category -> count
    toil_totals = {}       # toil_category -> hours
    action_statuses = {}   # status -> count
    mttr_values = []       # list of MTTR seconds

    for pm in postmortems:
        inc_id = pm.get("id", "unknown")
        sev = pm["severity"]
        rcc = pm["root_cause_category"]

        # Incident count
        incident_total.labels(severity=sev, root_cause_category=rcc).inc()

        # Repeat incident tracking
        category_counts[rcc] = category_counts.get(rcc, 0) + 1

        # MTTR calculation
        det = _parse_datetime(pm.get("detection_time", ""))
        res = _parse_datetime(pm.get("resolution_time", ""))
        if det and res:
            mttr_sec = (res - det).total_seconds()
            incident_mttr.labels(
                incident_id=inc_id, severity=sev, root_cause_category=rcc,
            ).set(mttr_sec)
            mttr_values.append(mttr_sec)

        # Toil hours
        for cat, hours in pm.get("toil_hours", {}).items():
            if cat in VALID_TOIL_CATEGORIES:
                toil_totals[cat] = toil_totals.get(cat, 0.0) + hours

        # Action items
        for ai in pm.get("action_items", []):
            st = ai.get("status", "open")
            action_statuses[st] = action_statuses.get(st, 0) + 1

    # Set repeat incident gauges
    for rcc, count in category_counts.items():
        repeat_incident.labels(root_cause_category=rcc).set(count)

    # Set toil gauges
    for cat, hours in toil_totals.items():
        toil_hours.labels(toil_category=cat).set(hours)

    # Set action item gauges
    for st, count in action_statuses.items():
        action_item_total.labels(status=st).set(count)

    # Set average MTTR
    if mttr_values:
        mttr_average.set(sum(mttr_values) / len(mttr_values))

    log.info(
        "Refreshed: %d postmortems, %d action items, avg MTTR=%.0fs",
        len(postmortems),
        sum(action_statuses.values()),
        sum(mttr_values) / len(mttr_values) if mttr_values else 0,
    )

    return registry


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------
app = FastAPI(title="Incident Metrics Exporter — Operational Excellence Demo")


@app.on_event("startup")
async def on_startup():
    pms = _load_postmortems()
    log.info(
        "Exporter started: %d postmortems loaded from %s",
        len(pms), POSTMORTEM_DIR,
    )


@app.get("/health")
async def health():
    return {"status": "ok", "service": "incident-metrics-exporter"}


@app.get("/metrics")
async def metrics():
    registry = _build_metrics()
    return Response(
        content=generate_latest(registry),
        media_type="text/plain; version=0.0.4; charset=utf-8",
    )


@app.get("/postmortems")
async def list_postmortems():
    """List loaded postmortems — useful for preflight checks."""
    pms = _load_postmortems()
    return {
        "count": len(pms),
        "incidents": [
            {
                "id": pm.get("id"),
                "severity": pm.get("severity"),
                "root_cause_category": pm.get("root_cause_category"),
            }
            for pm in pms
        ],
    }
