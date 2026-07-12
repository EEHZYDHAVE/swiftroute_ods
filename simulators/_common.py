"""
simulators/_common.py

Shared helpers used by every incremental simulator. Not runnable on its
own — imported by simulate_*.py and run_simulation.py.

Design principle: date-range resolution happens ONCE (in run_simulation.py,
using resolve_date_range() below), then gets passed explicitly to every
simulator. No individual simulator re-derives "where did we leave off" —
that would risk Samsara (or anything else) re-scanning full history and
regenerating already-loaded periods.
"""

import os
import sys
import json
import glob
from datetime import datetime, timedelta, timezone

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATORS_DIR = os.path.join(PROJECT_ROOT, "generators")
DATA_ROOT = os.path.join(PROJECT_ROOT, "source_data", "raw")   # matches existing generators' OUTPUT_BASE convention

sys.path.insert(0, GENERATORS_DIR)
import shared_ids  # noqa: E402  (import after sys.path adjustment, by necessity)


def system_path(*parts):
    return os.path.join(DATA_ROOT, *parts)


# ══════════════════════════════════════════════════════════════════════════
#  DATE RANGE RESOLUTION — called once, by run_simulation.py
# ══════════════════════════════════════════════════════════════════════════

def latest_onfleet_date():
    """Scans existing Onfleet task files to find the latest date already
    simulated (historical or prior incremental runs). Onfleet is used as
    the reference system since every other simulator's timing ultimately
    keys off it (directly for Samsara, indirectly for billing/orders)."""
    onfleet_folder = system_path("onfleet")
    month_folders = sorted(
        d for d in os.listdir(onfleet_folder)
        if os.path.isdir(os.path.join(onfleet_folder, d)) and d != "workers"
    )
    if not month_folders:
        return None

    latest_month = month_folders[-1]
    pages = sorted(glob.glob(os.path.join(onfleet_folder, latest_month, "page_*.json")))
    if not pages:
        return None

    max_ms = 0
    with open(pages[-1]) as fh:
        payload = json.load(fh)
    for task in payload["tasks"]:
        max_ms = max(max_ms, task["timeCreated"])

    return datetime.fromtimestamp(max_ms / 1000, tz=timezone.utc).date()


def resolve_date_range(start_date_str, days=7):
    """Returns (start_date, end_date) as date objects.
    - If start_date_str is given, use it as-is (explicit override).
    - Otherwise, resume the day after the latest date found in existing
      Onfleet data. Falls back to 2025-07-01 if no Onfleet data exists at
      all yet (shouldn't happen if the original generators already ran)."""
    if start_date_str:
        start = datetime.strptime(start_date_str, "%Y-%m-%d").date()
    else:
        latest = latest_onfleet_date()
        if latest is None:
            start = datetime(2025, 7, 1).date()
        else:
            start = latest + timedelta(days=1)

    end = start + timedelta(days=days - 1)
    return start, end


def daterange(start_date, end_date):
    """Yields each date in [start_date, end_date] inclusive."""
    d = start_date
    while d <= end_date:
        yield d
        d += timedelta(days=1)


# ══════════════════════════════════════════════════════════════════════════
#  FILE CONTINUATION HELPERS — find the next unused name so nothing
#  collides with existing files (and pipeline_state stays meaningful)
# ══════════════════════════════════════════════════════════════════════════

def next_page_number(folder):
    """Looks at existing page_XXXX.json files in a folder and returns the
    next unused page number (1 if the folder is empty/doesn't exist)."""
    if not os.path.isdir(folder):
        return 1
    existing = glob.glob(os.path.join(folder, "page_*.json"))
    if not existing:
        return 1
    numbers = []
    for p in existing:
        name = os.path.basename(p)
        try:
            numbers.append(int(name.replace("page_", "").replace(".json", "")))
        except ValueError:
            continue
    return (max(numbers) + 1) if numbers else 1


def write_json(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, ensure_ascii=False)


def month_key(d):
    return f"{d.year}_{str(d.month).zfill(2)}"
