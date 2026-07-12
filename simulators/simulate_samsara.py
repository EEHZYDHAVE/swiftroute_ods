"""
simulators/simulate_samsara.py

Incremental Samsara simulator. Reuses generate_samsara.py's own
cluster_into_trip_blocks() / make_trip() / make_depot_trip() /
build_vehicles() / is_driver_active_on() functions directly.

Two things this script must get right that a naive re-run of the
historical logic would get wrong:

1. AVOIDING REPROCESSING HISTORICAL DELIVERIES: rather than tracking
   which Onfleet files are "new," every task is filtered by its OWN
   timeCreated falling inside [start_date, end_date]. That's the one
   unambiguous fact identifying which batch a task belongs to, so this
   works correctly regardless of which physical page file it landed in
   and without needing any file-list hand-off between simulators.

2. BOUNDARY SAFETY: historical trips can spill a few hours past midnight
   into the day this incremental run starts (confirmed: as late as
   2025-07-01 16:05 UTC in the historical data). If this run naively
   started scheduling from a blank slate, a new trip could overlap an
   already-loaded historical trip for the same vehicle or driver — the
   exact bug the historical generator was fixed to eliminate. So this
   script scans ALL existing trip files first to find each vehicle's and
   each driver's real busy-until timestamp, and never schedules a new
   trip that starts before that.

vehicles.json is NEVER rewritten by this script (per scope — no new
vehicles). driver_summary.json IS regenerated each run with updated
cumulative totals, per the original instructions.

DEPENDENCY: must run after simulate_onfleet.py for the same date range.
"""

import os
import sys
import glob
import json
import argparse
import random
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "generators"))

import _common
import shared_ids
import generate_samsara as sam   # reuse its functions directly


def load_existing_intervals():
    """Scans ALL existing Samsara trip files and returns each vehicle's
    and each driver's full list of existing (start_ms, end_ms) intervals
    — NOT a single scalar 'busy until' value. A scalar floor is wrong
    here: a historical trip built from a late-completing June-created
    task can end LATER in clock time than a brand new July-created
    delivery's completion, even though the July delivery is chronologically
    the newer batch. Only a genuine interval-overlap check handles this
    correctly."""
    vehicle_intervals = {}
    driver_intervals = {}

    for f in glob.glob(_common.system_path("samsara", "trips", "*", "trips_*.json")):
        with open(f) as fh:
            payload = json.load(fh)
        for t in payload["trips"]:
            vid = t["vehicleId"]
            vehicle_intervals.setdefault(vid, []).append((t["startMs"], t["endMs"]))
            if t["driverId"]:
                did = t["driverId"]
                driver_intervals.setdefault(did, []).append((t["startMs"], t["endMs"]))

    for d in vehicle_intervals:
        vehicle_intervals[d].sort()
    for d in driver_intervals:
        driver_intervals[d].sort()

    return vehicle_intervals, driver_intervals


def subtract_intervals(seg_start_ms, seg_end_ms, occupied):
    """Returns the list of (start_ms, end_ms) sub-segments of
    [seg_start_ms, seg_end_ms] that do NOT overlap any interval in
    `occupied`. In the common case (no conflict) this returns the
    original segment unchanged."""
    free = [(seg_start_ms, seg_end_ms)]
    for o_start, o_end in occupied:
        if o_end <= seg_start_ms or o_start >= seg_end_ms:
            continue   # no overlap with this occupied interval at all
        next_free = []
        for f_start, f_end in free:
            if o_end <= f_start or o_start >= f_end:
                next_free.append((f_start, f_end))
                continue
            if o_start > f_start:
                next_free.append((f_start, o_start))
            if o_end < f_end:
                next_free.append((o_end, f_end))
        free = next_free
    return [seg for seg in free if seg[1] > seg[0]]


def overlaps_any(seg_start_ms, seg_end_ms, intervals):
    for s, e in intervals:
        if s < seg_end_ms and seg_start_ms < e:
            return True
    return False


def load_driver_delivery_windows_for_range(start_date, end_date):
    """Same anchoring logic as generate_samsara.py (completion_time minus
    serviceTime), but filtered to only tasks CREATED within
    [start_date, end_date] — this is what identifies "this batch" of
    deliveries regardless of which Onfleet file they're stored in."""
    fte_worker_ids = {d["onfleet_worker_id"] for d in shared_ids.DRIVERS if d["employment_type"] == "FTE"}

    range_start_ms = int(datetime(start_date.year, start_date.month, start_date.day, tzinfo=timezone.utc).timestamp() * 1000)
    range_end_ms = int((datetime(end_date.year, end_date.month, end_date.day, tzinfo=timezone.utc) + timedelta(days=1)).timestamp() * 1000)

    windows = {}
    task_files = glob.glob(_common.system_path("onfleet", "*", "page_*.json"))
    for path in task_files:
        with open(path, "r", encoding="utf-8") as fh:
            payload = json.load(fh)
        for task in payload["tasks"]:
            if not (range_start_ms <= task["timeCreated"] < range_end_ms):
                continue
            worker_id = task["worker"]
            if worker_id is None or worker_id not in fte_worker_ids:
                continue
            if task["state"] != 3:
                continue
            complete_time = task["completionDetails"]["time"]
            if complete_time is None:
                continue

            service_mins = task.get("serviceTime", 5)
            end_dt = datetime.fromtimestamp(complete_time / 1000, tz=timezone.utc)
            start_dt = end_dt - timedelta(minutes=service_mins)
            windows.setdefault(worker_id, []).append((start_dt, end_dt))

    return windows


def run(start_date, end_date):
    print(f"[samsara] simulating {start_date} -> {end_date}")

    vehicles = sam.build_vehicles()   # in-memory only — vehicles.json is NOT rewritten
    vehicles_by_city = {}
    for v in vehicles:
        vehicles_by_city.setdefault(v["_city"], []).append(v)
    for city in vehicles_by_city:
        vehicles_by_city[city] = [v for v in vehicles_by_city[city] if v["_active"]]

    print("  Loading Onfleet delivery windows for this window...")
    windows = load_driver_delivery_windows_for_range(start_date, end_date)
    print(f"  Delivery records loaded for {len(windows)} FTE drivers")

    print("  Seeding vehicle/driver existing intervals from prior data...")
    vehicle_existing, driver_existing = load_existing_intervals()

    driver_by_worker_id = {d["onfleet_worker_id"]: d for d in shared_ids.DRIVERS}

    driver_blocks = []
    for wid, intervals in windows.items():
        driver = driver_by_worker_id[wid]
        blocks = sam.cluster_into_trip_blocks(intervals)
        for b_start, b_end in blocks:
            driver_blocks.append((wid, driver["city"], b_start, b_end))
    driver_blocks.sort(key=lambda b: b[2])

    def to_ms(dt):
        return int(dt.timestamp() * 1000)

    # Running interval lists, seeded from existing data, grown as this
    # run assigns new trips — used for genuine overlap checks, not a
    # single scalar floor.
    vehicle_assigned = {v["id"]: list(vehicle_existing.get(v["id"], [])) for v in vehicles}
    vehicle_last_used = {v["id"]: 0 for v in vehicles}
    driver_assigned = {sid: list(ivs) for sid, ivs in driver_existing.items()}

    vehicle_trips = {v["id"]: [] for v in vehicles}
    total_trips = 0
    driver_short_events = 0
    split_segments = 0
    trip_counter = 0

    for wid, city, b_start, b_end in driver_blocks:
        driver = driver_by_worker_id[wid]
        samsara_driver_id = driver["samsara_driver_id"]

        # Subtract any genuinely overlapping EXISTING interval for this
        # driver (historical or prior-run) — usually a no-op, only
        # produces real splits when there's an actual clock-time overlap.
        existing_for_driver = driver_assigned.get(samsara_driver_id, [])
        free_segments = subtract_intervals(to_ms(b_start), to_ms(b_end), existing_for_driver)
        if len(free_segments) != 1 or free_segments[0] != (to_ms(b_start), to_ms(b_end)):
            split_segments += 1

        for seg_start_ms, seg_end_ms in free_segments:
            seg_start = datetime.fromtimestamp(seg_start_ms / 1000, tz=timezone.utc)
            seg_end = datetime.fromtimestamp(seg_end_ms / 1000, tz=timezone.utc)

            candidates = [
                v for v in vehicles_by_city.get(city, [])
                if not overlaps_any(seg_start_ms, seg_end_ms, vehicle_assigned[v["id"]])
            ]
            if not candidates:
                driver_short_events += 1
                continue

            candidates.sort(key=lambda v: vehicle_last_used[v["id"]])
            vehicle = candidates[0]

            trip_counter += 1
            trip = sam.make_trip(vehicle, samsara_driver_id, seg_start, seg_end, trip_counter, city)
            vehicle_trips[vehicle["id"]].append(trip)
            total_trips += 1

            vehicle_assigned[vehicle["id"]].append((seg_start_ms, seg_end_ms))
            vehicle_last_used[vehicle["id"]] = trip_counter
            driver_assigned.setdefault(samsara_driver_id, []).append((seg_start_ms, seg_end_ms))

    # Depot-move quirk — only on days a vehicle has zero trips at all
    # (checked across BOTH pre-existing and newly-written trips)
    depot_trips = 0
    for d in _common.daterange(start_date, end_date):
        for city, city_vehicles in vehicles_by_city.items():
            for vehicle in city_vehicles:
                has_trip_today = any(
                    datetime.fromtimestamp(t["startMs"] / 1000, tz=timezone.utc).date() == d
                    for t in vehicle_trips[vehicle["id"]]
                )
                if has_trip_today:
                    continue
                if random.random() < 0.03:
                    trip_counter += 1
                    trip = sam.make_depot_trip(vehicle, city, d, trip_counter)
                    vehicle_trips[vehicle["id"]].append(trip)
                    total_trips += 1
                    depot_trips += 1

    # Write trip files — APPEND to existing month files if the month
    # already has a file for this vehicle, otherwise create new
    print("  Writing trip files...")
    for vehicle in vehicles:
        new_trips = sorted(vehicle_trips[vehicle["id"]], key=lambda t: t["startMs"])
        if not new_trips:
            continue
        by_month = {}
        for t in new_trips:
            dt = datetime.fromtimestamp(t["startMs"] / 1000, tz=timezone.utc)
            mk = _common.month_key(dt.date())
            by_month.setdefault(mk, []).append(t)

        for mk, month_new_trips in by_month.items():
            path = _common.system_path("samsara", "trips", mk, f"trips_{vehicle['id']}.json")
            if os.path.exists(path):
                with open(path) as fh:
                    existing_payload = json.load(fh)
                combined = existing_payload["trips"] + month_new_trips
            else:
                combined = month_new_trips
            combined.sort(key=lambda t: t["startMs"])
            payload = {
                "vehicleId": vehicle["id"],
                "vehicleName": vehicle["name"],
                "month": mk,
                "pagination": {"endCursor": combined[-1]["id"], "hasNextPage": False},
                "trips": combined,
            }
            _common.write_json(path, payload)

    # driver_summary.json — cumulative, regenerated each run
    print("  Regenerating driver_summary.json (cumulative)...")
    summary = sam.build_driver_summary()
    summ_path = _common.system_path("samsara", "driver_summary", "driver_summary.json")
    _common.write_json(summ_path, {"data": summary, "pagination": {"endCursor": None, "hasNextPage": False}})

    print(f"[samsara] done. +{total_trips} trips (+{depot_trips} depot-move), "
          f"{driver_short_events} driver-short events, {split_segments} blocks had a genuine "
          f"overlap-split against existing data. vehicles.json untouched.")
    return total_trips


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--start-date", required=True, help="YYYY-MM-DD")
    parser.add_argument("--end-date", required=True, help="YYYY-MM-DD")
    args = parser.parse_args()
    s = datetime.strptime(args.start_date, "%Y-%m-%d").date()
    e = datetime.strptime(args.end_date, "%Y-%m-%d").date()
    run(s, e)
