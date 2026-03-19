"""
Webhook Stub — simulates PagerDuty and Slack receivers.

Prints every alert arrival with ANSI colors so alert lines
pop on camera during the demo recording.
Supports /divider endpoint to print a visual separator between demo scenes.
"""

import logging
from typing import Optional

from fastapi import FastAPI, Request

app = FastAPI(title="Webhook Alert Receiver Stub")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-5s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("webhook-stub")

# ANSI color codes
RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
BOLD = "\033[1m"
DIM = "\033[2m"
RESET = "\033[0m"


@app.get("/health")
async def health():
    return {"status": "ok", "service": "webhook-stub"}


@app.post("/divider/{label}")
async def divider(label: str):
    """Print a visual divider in the log — call between demo scenes."""
    log.info(
        "%s%s──────────────────────────────────────────────%s", CYAN, BOLD, RESET,
    )
    log.info(
        "%s%s  SCENE: %s%s", CYAN, BOLD, label.upper(), RESET,
    )
    log.info(
        "%s%s──────────────────────────────────────────────%s", CYAN, BOLD, RESET,
    )
    return {"divider": label}


@app.post("/webhook/{receiver}")
async def receive(receiver: str, request: Request):
    body = await request.json()
    alerts = body.get("alerts", [])
    for a in alerts:
        alertname = a.get("labels", {}).get("alertname", "unknown")
        severity = a.get("labels", {}).get("severity", "unknown")
        status = a.get("status", "unknown")

        # Color by status
        if status == "firing":
            status_color = f"{RED}{BOLD}firing{RESET}"
        elif status == "resolved":
            status_color = f"{GREEN}{BOLD}resolved{RESET}"
        else:
            status_color = status

        # Color by severity
        if severity == "critical":
            sev_color = f"{RED}critical{RESET}"
        elif severity == "warning":
            sev_color = f"{YELLOW}warning{RESET}"
        else:
            sev_color = severity

        # Color receiver
        if "pagerduty" in receiver:
            recv_color = f"{RED}{BOLD}{receiver}{RESET}"
        elif "slack" in receiver:
            recv_color = f"{CYAN}{BOLD}{receiver}{RESET}"
        else:
            recv_color = receiver

        log.info(
            "ALERT  receiver=%-20s  status=%-18s  alertname=%-28s  severity=%s",
            recv_color, status_color, alertname, sev_color,
        )
    return {"status": "ok", "received": len(alerts)}
