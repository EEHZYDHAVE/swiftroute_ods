"""
simulators/simulate_gusto.py

Incremental Gusto simulator. employees.json is NEVER touched (headcount
changes are out of scope). A new payroll file is only produced when a
bi-weekly check date falls inside [start_date, end_date] — most 7-day
runs will produce nothing at all, which is correct (payroll is
genuinely periodic, not continuous).

Continuation logic: scans existing payroll_*.json files to find the
latest pay_period.end_date, then derives the next period mathematically
(14-day periods, check_date = period_end + 3 days) — no separate state
file needed.
"""

import os
import sys
import glob
import json
import argparse
from datetime import datetime, timedelta

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "generators"))

import _common
import generate_gusto as gus


def latest_period_end():
    """Scans existing payroll files for the latest pay_period.end_date."""
    files = glob.glob(_common.system_path("gusto", "payrolls", "payroll_*.json"))
    latest = None
    for f in files:
        with open(f) as fh:
            payload = json.load(fh)
        end = datetime.strptime(payload["pay_period"]["end_date"], "%Y-%m-%d").date()
        if latest is None or end > latest:
            latest = end
    return latest


def next_periods_in_window(start_date, end_date):
    """Yields (period_start, period_end, check_date, period_index) for
    every bi-weekly period whose check_date falls inside the run window.
    Almost always yields 0 or 1 period for a 7-day run; loops defensively
    in case a larger --days value spans more than one."""
    anchor = datetime(2025, 1, 1).date()
    last_end = latest_period_end()
    if last_end is None:
        raise RuntimeError("No existing Gusto payroll files found — run the historical generators first.")

    period_start = last_end + timedelta(days=1)
    while True:
        period_end = period_start + timedelta(days=13)
        check_date = period_end + timedelta(days=3)
        if check_date > end_date:
            break
        if check_date >= start_date:
            period_index = (period_start - anchor).days // 14
            yield (period_start.strftime("%Y-%m-%d"), period_end.strftime("%Y-%m-%d"),
                   check_date.strftime("%Y-%m-%d"), period_index)
        period_start = period_end + timedelta(days=1)


def run(start_date, end_date):
    print(f"[gusto] simulating {start_date} -> {end_date}")

    periods = list(next_periods_in_window(start_date, end_date))
    if not periods:
        print("[gusto] no payroll check date falls in this window — nothing to do. employees.json untouched.")
        return 0

    with open(_common.system_path("gusto", "employees", "employees.json")) as fh:
        employees = json.load(fh)

    total = 0
    for period_start, period_end, check_date, period_index in periods:
        payroll = gus.make_payroll((period_start, period_end, check_date), employees, period_index)
        path = _common.system_path("gusto", "payrolls", f"payroll_{check_date}.json")
        _common.write_json(path, payroll)
        n = len(payroll["employee_compensations"])
        print(f"  new payroll: {period_start} -> {period_end}, check {check_date}, {n} employees")
        total += 1

    print(f"[gusto] done. +{total} payroll file(s). employees.json untouched.")
    return total


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--start-date", required=True)
    parser.add_argument("--end-date", required=True)
    args = parser.parse_args()
    s = datetime.strptime(args.start_date, "%Y-%m-%d").date()
    e = datetime.strptime(args.end_date, "%Y-%m-%d").date()
    run(s, e)
