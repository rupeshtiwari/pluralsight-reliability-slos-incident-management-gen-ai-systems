#!/usr/bin/env python3
"""
score_backlog.py — Prioritize Reliability Backlog

Reads all postmortem YAML files, extracts action items, scores each
using: priority = impact + likelihood - effort, and prints a ranked table.

Higher score ships first.
Simple, transparent scoring beats vague backlog debates.

Usage:
    python3 score_backlog.py
    python3 score_backlog.py --postmortem-dir ./postmortems
"""

import argparse
import glob
import os
import sys

import yaml

# ---------------------------------------------------------------------------
# ANSI colors for terminal output (camera-friendly on dark background)
# ---------------------------------------------------------------------------
RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
WHITE = "\033[97m"
BOLD = "\033[1m"
DIM = "\033[2m"
RESET = "\033[0m"
BG_RED = "\033[41m"
BG_GREEN = "\033[42m"
BG_YELLOW = "\033[43m"

# Box-drawing characters (UTF-8)
TL = "\u250c"  # top-left
TR = "\u2510"  # top-right
BL = "\u2514"  # bottom-left
BR = "\u2518"  # bottom-right
H = "\u2500"   # horizontal
V = "\u2502"   # vertical
TJ = "\u252c"  # top junction
BJ = "\u2534"  # bottom junction
LJ = "\u251c"  # left junction
RJ = "\u2524"  # right junction
CJ = "\u253c"  # cross junction

# Column widths (visible characters)
W_RANK = 6
W_DESC = 46
W_I = 5
W_L = 5
W_E = 5
W_SCORE = 7
W_OWNER = 18
W_SOURCE = 14

COL_WIDTHS = [W_RANK, W_DESC, W_I, W_L, W_E, W_SCORE, W_OWNER, W_SOURCE]


# ---------------------------------------------------------------------------
# Controlled enums — must match schema.yaml
# ---------------------------------------------------------------------------
VALID_TOIL_CATEGORIES = {
    "cascading_failure_recovery", "alert_noise_triage",
    "manual_scaling", "manual_deploy", "manual_postmortem",
}


def _hline(left, mid, right):
    """Build a horizontal line using box-drawing characters."""
    segments = [H * w for w in COL_WIDTHS]
    return left + mid.join(segments) + right


def _row(*cells):
    """Build a table row. Each cell is (text, visible_width_target)."""
    parts = []
    for text, width in zip(cells, COL_WIDTHS):
        # Strip ANSI to measure visible length
        import re
        visible = re.sub(r'\033\[[0-9;]*m', '', text)
        pad = width - len(visible)
        if pad < 0:
            pad = 0
        parts.append(text + " " * pad)
    return V + (V).join(parts) + V


def _color_score(score):
    """Color-code a score value for camera visibility."""
    s = str(score)
    if score >= 7:
        return f"{RED}{BOLD}{s}{RESET}"
    elif score >= 5:
        return f"{YELLOW}{BOLD}{s}{RESET}"
    else:
        return f"{DIM}{s}{RESET}"


def _color_rank(rank, score):
    """Color-code rank to match score color."""
    r = str(rank)
    if score >= 7:
        return f"{RED}{BOLD}{r}{RESET}"
    elif score >= 5:
        return f"{YELLOW}{r}{RESET}"
    else:
        return f"{DIM}{r}{RESET}"


def _color_ile(val, label):
    """Color I/L/E values — high impact/likelihood green, high effort red."""
    s = str(val)
    if label in ("I", "L"):
        if val >= 5:
            return f"{GREEN}{BOLD}{s}{RESET}"
        elif val >= 4:
            return f"{GREEN}{s}{RESET}"
        else:
            return f"{WHITE}{s}{RESET}"
    else:  # effort
        if val >= 3:
            return f"{RED}{s}{RESET}"
        elif val <= 1:
            return f"{GREEN}{s}{RESET}"
        else:
            return f"{WHITE}{s}{RESET}"


def load_action_items(postmortem_dir):
    # type: (str) -> list
    """Load all action items from postmortem YAML files."""
    pattern = os.path.join(postmortem_dir, "INC-*.yaml")
    files = sorted(glob.glob(pattern))
    items = []

    for fpath in files:
        with open(fpath, "r") as f:
            data = yaml.safe_load(f)
        if not data:
            continue

        inc_id = data.get("id", "unknown")
        rcc = data.get("root_cause_category", "unknown")

        for ai in data.get("action_items", []):
            impact = ai.get("impact", 0)
            likelihood = ai.get("likelihood", 0)
            effort = ai.get("effort", 0)
            score = impact + likelihood - effort

            items.append({
                "incident": inc_id,
                "ai_id": ai.get("id", "?"),
                "description": ai.get("description", ""),
                "owner": ai.get("owner", "unassigned"),
                "status": ai.get("status", "open"),
                "impact": impact,
                "likelihood": likelihood,
                "effort": effort,
                "score": score,
                "toil_category": ai.get("toil_category", ""),
                "root_cause_category": rcc,
            })

    return items


def print_ranked_table(items):
    # type: (list) -> None
    """Print ranked backlog table with box borders and color coding."""
    ranked = sorted(items, key=lambda x: x["score"], reverse=True)

    top_line = _hline(TL, TJ, TR)
    mid_line = _hline(LJ, CJ, RJ)
    bot_line = _hline(BL, BJ, BR)

    print()
    print(f"  {BOLD}{CYAN}RELIABILITY BACKLOG — Ranked by Priority Score{RESET}")
    print(f"  {DIM}Formula: priority = impact + likelihood - effort{RESET}")
    print(f"  {DIM}Higher score ships first{RESET}")
    print()

    # Table header
    print(top_line)
    header = _row(
        f"{BOLD} Rank",
        f"{BOLD} Action Item",
        f"{BOLD}  I",
        f"{BOLD}  L",
        f"{BOLD}  E",
        f"{BOLD} Score",
        f"{BOLD} Owner",
        f"{BOLD} Source",
    )
    print(header + RESET)
    print(mid_line)

    # Data rows
    for rank, item in enumerate(ranked, 1):
        score = item["score"]

        desc = item["description"]
        if len(desc) > 44:
            desc = desc[:41] + "..."

        row = _row(
            " " + _color_rank(rank, score),
            " " + desc,
            " " + _color_ile(item["impact"], "I"),
            " " + _color_ile(item["likelihood"], "L"),
            " " + _color_ile(item["effort"], "E"),
            "  " + _color_score(score),
            " " + item["owner"],
            " " + item["incident"],
        )
        print(row)

        # Separator between rows (except after last)
        if rank < len(ranked):
            print(mid_line)

    print(bot_line)

    # Summary below table
    open_count = sum(1 for i in ranked if i["status"] == "open")
    top = ranked[0] if ranked else None
    print()
    print(f"  {CYAN}Total action items:{RESET}  {BOLD}{len(ranked)}{RESET}")
    print(f"  {CYAN}Open:{RESET}               {BOLD}{open_count}{RESET}")
    if top:
        print(
            f"  {CYAN}Top priority:{RESET}       "
            f"{RED}{BOLD}{top['description']}{RESET}"
        )
        print(
            f"                       "
            f"{DIM}score {top['score']}, from {top['incident']}{RESET}"
        )

    # Repeat incident insight
    rcc_counts = {}
    for item in ranked:
        rcc = item["root_cause_category"]
        if rcc not in rcc_counts:
            rcc_counts[rcc] = set()
        rcc_counts[rcc].add(item["incident"])

    repeats = {k: v for k, v in rcc_counts.items() if len(v) > 1}
    if repeats:
        print()
        print(f"  {YELLOW}{BOLD}REPEAT INCIDENT FAMILIES:{RESET}")
        for rcc, incidents in repeats.items():
            print(
                f"    {RED}{BOLD}{rcc}{RESET}: appears in "
                f"{BOLD}{len(incidents)}{RESET} postmortems "
                f"({', '.join(sorted(incidents))})"
            )

    print()


def main():
    parser = argparse.ArgumentParser(description="Score and rank reliability backlog")
    parser.add_argument(
        "--postmortem-dir",
        default=os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "postmortems",
        ),
        help="Directory containing postmortem YAML files",
    )
    args = parser.parse_args()

    if not os.path.isdir(args.postmortem_dir):
        print(f"ERROR: directory not found: {args.postmortem_dir}", file=sys.stderr)
        sys.exit(1)

    items = load_action_items(args.postmortem_dir)
    if not items:
        print("No action items found in postmortem files.", file=sys.stderr)
        sys.exit(1)

    print_ranked_table(items)


if __name__ == "__main__":
    main()
