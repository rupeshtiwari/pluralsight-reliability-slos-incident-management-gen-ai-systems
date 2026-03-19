#!/usr/bin/env python3
"""
show_postmortem.py — Pretty-print a Blameless Postmortem

Reads a postmortem YAML file and displays it with:
  - Color-coded sections (timeline, root cause, evidence, action items)
  - Box-drawing borders for structure
  - Highlighted blameless framing (system gap, no names)
  - Impact/Likelihood/Effort scores visible in action items
  - Toil hours summary

Usage:
    python3 show_postmortem.py postmortems/INC-2024-001.yaml
"""

import sys
import os
from datetime import datetime
from typing import Optional

import yaml

# ---------------------------------------------------------------------------
# ANSI colors
# ---------------------------------------------------------------------------
RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
BLUE = "\033[94m"
MAGENTA = "\033[95m"
CYAN = "\033[96m"
WHITE = "\033[97m"
BOLD = "\033[1m"
DIM = "\033[2m"
RESET = "\033[0m"
BG_RED = "\033[48;5;52m"
BG_BLUE = "\033[48;5;17m"
BG_GREEN = "\033[48;5;22m"
BG_YELLOW = "\033[48;5;58m"

# Box-drawing
TL = "\u250c"
TR = "\u2510"
BL = "\u2514"
BR = "\u2518"
H = "\u2500"
V = "\u2502"
LJ = "\u251c"
RJ = "\u2524"

W = 80  # total box width


def _box_top(title=""):
    if title:
        t = f" {title} "
        return TL + H * 2 + f"{BOLD}{CYAN}{t}{RESET}" + H * (W - 3 - len(t)) + TR
    return TL + H * (W - 2) + TR


def _box_mid(title=""):
    if title:
        t = f" {title} "
        return LJ + H * 2 + f"{BOLD}{CYAN}{t}{RESET}" + H * (W - 3 - len(t)) + RJ
    return LJ + H * (W - 2) + RJ


def _box_bot():
    return BL + H * (W - 2) + BR


def _box_line(text, indent=2):
    return f"{V}{' ' * indent}{text}"


def _parse_dt(dt_str):
    try:
        if dt_str.endswith("Z"):
            dt_str = dt_str[:-1] + "+00:00"
        return datetime.fromisoformat(dt_str)
    except (ValueError, AttributeError):
        return None


def show_postmortem(filepath):
    with open(filepath, "r") as f:
        data = yaml.safe_load(f)

    if not data:
        print("ERROR: Empty YAML file")
        return

    inc_id = data.get("id", "unknown")
    title = data.get("title", "Untitled")
    severity = data.get("severity", "?")
    rcc = data.get("root_cause_category", "?")
    date = data.get("date", "?")

    det = _parse_dt(data.get("detection_time", ""))
    res = _parse_dt(data.get("resolution_time", ""))
    mttr_min = int((res - det).total_seconds() / 60) if det and res else 0

    # Severity color
    sev_color = RED if severity == "SEV1" else YELLOW if severity == "SEV2" else WHITE

    print()

    # ── HEADER ──
    print(_box_top("BLAMELESS POST-INCIDENT REVIEW"))
    print(_box_line(f"{BOLD}{WHITE}{inc_id}{RESET}  {DIM}{date}{RESET}"))
    print(_box_line(f"{BOLD}{title}{RESET}"))
    print(_box_line(""))
    print(_box_line(f"Severity:    {sev_color}{BOLD}{severity}{RESET}"))
    print(_box_line(f"Category:    {YELLOW}{rcc}{RESET}"))
    if mttr_min:
        mttr_color = RED if mttr_min > 30 else YELLOW if mttr_min > 15 else GREEN
        print(_box_line(f"MTTR:        {mttr_color}{BOLD}{mttr_min} minutes{RESET}"))

    # ── TIMELINE ──
    timeline = data.get("timeline", [])
    if timeline:
        print(_box_mid("TIMELINE"))
        for entry in timeline:
            t = entry.get("time", "?")
            e = entry.get("event", "?")
            print(_box_line(f"{CYAN}{t}{RESET}  {e}"))

    # ── ROOT CAUSE (blameless) ──
    root_cause = data.get("root_cause", "")
    if root_cause:
        print(_box_mid("ROOT CAUSE (system gap \u2014 blameless)"))
        # Wrap text
        rc_text = root_cause.strip().replace("\n", " ")
        words = rc_text.split()
        line = ""
        for word in words:
            if len(line) + len(word) + 1 > 72:
                print(_box_line(f"{RED}{BOLD}{line}{RESET}"))
                line = word
            else:
                line = (line + " " + word).strip()
        if line:
            print(_box_line(f"{RED}{BOLD}{line}{RESET}"))

    # ── EVIDENCE ──
    evidence = data.get("evidence", [])
    if evidence:
        print(_box_mid("EVIDENCE"))
        type_colors = {"metric": GREEN, "trace": BLUE, "log": MAGENTA}
        for ev in evidence:
            etype = ev.get("type", "?")
            edesc = ev.get("description", "?")
            tc = type_colors.get(etype, WHITE)
            tag = f"{tc}{BOLD}[{etype.upper():6s}]{RESET}"
            print(_box_line(f"{tag}  {edesc}"))

    # ── ACTION ITEMS with I/L/E ──
    action_items = data.get("action_items", [])
    if action_items:
        print(_box_mid("ACTION ITEMS"))
        print(_box_line(
            f"{BOLD}{'ID':<8}{'Description':<44}  "
            f"{'I':>2}  {'L':>2}  {'E':>2}  "
            f"{'Owner':<16}{'Status'}{RESET}"
        ))
        print(_box_line(f"{DIM}{H * 72}{RESET}"))
        for ai in action_items:
            ai_id = ai.get("id", "?")
            desc = ai.get("description", "?")
            if len(desc) > 42:
                desc = desc[:39] + "..."
            imp = ai.get("impact", 0)
            lik = ai.get("likelihood", 0)
            eff = ai.get("effort", 0)
            owner = ai.get("owner", "?")
            status = ai.get("status", "?")

            # Color: high impact/likelihood = green, high effort = red
            def _pad_color(val, color_str):
                """Pad a colored single-digit value to 2 chars visible."""
                return color_str + " " * (2 - len(str(val)))

            ic = f"{GREEN}{BOLD}{imp}{RESET}" if imp >= 4 else f"{WHITE}{imp}{RESET}"
            lc = f"{GREEN}{BOLD}{lik}{RESET}" if lik >= 4 else f"{WHITE}{lik}{RESET}"
            ec = f"{RED}{BOLD}{eff}{RESET}" if eff >= 3 else f"{GREEN}{eff}{RESET}"
            sc = f"{YELLOW}{status}{RESET}" if status == "open" else f"{GREEN}{status}{RESET}"

            print(_box_line(
                f"{CYAN}{ai_id:<8}{RESET}{desc:<44}  "
                f"{ic}   {lc}   {ec}   "
                f"{owner:<16}{sc}"
            ))

    # ── TOIL HOURS ──
    toil = data.get("toil_hours", {})
    if toil:
        print(_box_mid("TOIL HOURS"))
        total = 0.0
        sorted_toil = sorted(toil.items(), key=lambda x: x[1], reverse=True)
        for cat, hours in sorted_toil:
            total += hours
            bar_len = int(hours * 4)
            bar = "\u2588" * bar_len
            h_color = RED if hours >= 3.0 else YELLOW if hours >= 1.5 else WHITE
            print(_box_line(
                f"{cat:<36s} {h_color}{BOLD}{hours:>5.1f}h{RESET}  {h_color}{bar}{RESET}"
            ))
        print(_box_line(f"{'':36s} {DIM}{'─' * 6}{RESET}"))
        print(_box_line(f"{'Total':<36s} {BOLD}{total:>5.1f}h{RESET}"))

    print(_box_bot())
    print()


def main():
    if len(sys.argv) < 2:
        script_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        default = os.path.join(script_dir, "postmortems", "INC-2024-001.yaml")
        if os.path.exists(default):
            show_postmortem(default)
        else:
            print(f"Usage: python3 {sys.argv[0]} <postmortem.yaml>")
            sys.exit(1)
    else:
        show_postmortem(sys.argv[1])


if __name__ == "__main__":
    main()
