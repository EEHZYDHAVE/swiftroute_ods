"""
simulators/simulate_onfleet.py

Incremental Onfleet simulator. Reuses generate_onfleet.py's own
build_drivers() / build_clients() / build_zones() / generate_day()
functions directly — no duplicated logic, no new entities. Only the
orchestration is new: operate over an arbitrary (start_date, end_date)
window instead of the fixed Jan-Jun 2025 range, and continue page
numbering from whatever already exists on disk instead of starting over
at page_0001.

workers.json is NEVER touched by this script (per the simplified scope —
no driver termination/hiring simulation).

Can be run standalone for testing, or imported and called by
run_simulation.py with an explicit date range.
"""

import os
import sys
import argparse
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "generators"))

import _common
import generate_onfleet as onf   # reuse its functions directly


def run(start_date, end_date):
    print(f"[onfleet] simulating {start_date} -> {end_date}")

    drivers = onf.build_drivers()
    clients = onf.build_clients()
    zones = onf.build_zones()

    month_tasks = {}   # month_key -> list of tasks
    total_tasks = 0

    for d in _common.daterange(start_date, end_date):
        dt = datetime(d.year, d.month, d.day, tzinfo=onf.START_DATE.tzinfo)
        day_tasks = onf.generate_day(dt, drivers, clients, zones)
        mk = _common.month_key(d)
        month_tasks.setdefault(mk, []).extend(day_tasks)
        total_tasks += len(day_tasks)

    total_pages = 0
    for mk, tasks in month_tasks.items():
        folder = _common.system_path("onfleet", mk)
        start_page = _common.next_page_number(folder)

        pages = [tasks[i:i + onf.PAGE_SIZE] for i in range(0, len(tasks), onf.PAGE_SIZE)]
        for i, page in enumerate(pages):
            page_num = start_page + i
            is_last = (i == len(pages) - 1)
            payload = {
                "lastId": None if is_last else page[-1]["id"],
                "tasks": page,
            }
            path = os.path.join(folder, f"page_{str(page_num).zfill(4)}.json")
            _common.write_json(path, payload)
        total_pages += len(pages)
        print(f"  {mk}: +{len(tasks)} tasks -> {len(pages)} new page(s) starting at page_{str(start_page).zfill(4)}")

    print(f"[onfleet] done. +{total_tasks} tasks, +{total_pages} pages. workers.json untouched.")
    return total_tasks


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--start-date", required=True, help="YYYY-MM-DD")
    parser.add_argument("--end-date", required=True, help="YYYY-MM-DD")
    args = parser.parse_args()
    s = datetime.strptime(args.start_date, "%Y-%m-%d").date()
    e = datetime.strptime(args.end_date, "%Y-%m-%d").date()
    run(s, e)
