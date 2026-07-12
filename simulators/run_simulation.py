"""
simulators/run_simulation.py

Master orchestrator for the incremental data simulator. Resolves the
date range ONCE, then runs all six system simulators against that exact
window, in the required order (Onfleet before Samsara — Samsara trips
are derived from Onfleet's task data).

Usage:
    uv run simulators/run_simulation.py
        Resumes from the day after the latest date already simulated
        (historical or a prior incremental run), for 7 days.

    uv run simulators/run_simulation.py --start-date 2025-07-15
        Overrides the start date explicitly. Still 7 days by default.

    uv run simulators/run_simulation.py --start-date 2025-07-15 --days 14
        Explicit start date, custom window length.

Run it again with no arguments any time to advance another 7 days —
no separate state file to maintain; the next window is always derived
fresh from what's already on disk.
"""

import os
import sys
import argparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common

import simulate_onfleet
import simulate_samsara
import simulate_gusto
import simulate_linnworks
import simulate_quickbooks
import simulate_salesforce


def main():
    parser = argparse.ArgumentParser(description="SwiftRoute incremental data simulator")
    parser.add_argument("--start-date", default=None, help="YYYY-MM-DD (default: resume from existing data)")
    parser.add_argument("--days", type=int, default=7, help="Length of the simulated window (default: 7)")
    args = parser.parse_args()

    start_date, end_date = _common.resolve_date_range(args.start_date, days=args.days)

    print("=" * 60)
    print(f"SwiftRoute incremental simulation: {start_date} -> {end_date}")
    print("=" * 60)
    print()

    # Order matters here: Onfleet must run before Samsara.
    # Gusto / Linnworks / QuickBooks / Salesforce have no cross-system
    # ordering dependency and could run in any order.
    simulate_onfleet.run(start_date, end_date)
    print()
    simulate_samsara.run(start_date, end_date)
    print()
    simulate_gusto.run(start_date, end_date)
    print()
    simulate_linnworks.run(start_date, end_date)
    print()
    simulate_quickbooks.run(start_date, end_date)
    print()
    simulate_salesforce.run(start_date, end_date)

    print()
    print("=" * 60)
    print(f"Simulation complete for {start_date} -> {end_date}.")
    print("Run this script again (no arguments) to advance another window.")
    print("=" * 60)


if __name__ == "__main__":
    main()
