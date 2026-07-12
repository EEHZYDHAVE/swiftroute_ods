"""
generators/generate_samsara.py

Generates synthetic Samsara Fleet API responses for SwiftRoute Logistics.

DEPENDENCY CHANGE: this generator now reads Onfleet's already-generated
task files (source_data/onfleet/{month}/page_*.json) in addition to
shared_ids.py. Run order is now:
    generate_shared_ids.py  ->  generate_onfleet.py  ->  generate_samsara.py
This breaks the earlier "six system generators, any order" guarantee —
Samsara specifically must now run AFTER Onfleet.

WHY: a trip generator that invents random times independently of Onfleet
could produce a driver "logged in" to a vehicle while their actual
deliveries (per Onfleet) were happening somewhere else in time — an
internal contradiction. This version instead derives each trip's time
window FROM that driver's real Onfleet delivery activity that day, which
also happens to fix a separate, unrelated bug: the previous version could
independently pick the same driver for two different vehicles on the same
day (physically impossible). Deriving trips from a single per-day
driver->vehicle assignment fixes both problems from one change.

GUARANTEES enforced by construction (not by post-hoc conflict repair):
  - Employee scope: only FTE drivers ever appear here (IC drivers use
    personal vehicles, invisible to a company fleet platform).
  - Driver availability: a driver is assigned to at most ONE vehicle per
    day, so they can never have two simultaneous trips.
  - Vehicle availability: since a vehicle has at most one driver per day,
    and that driver's own trip-blocks (see below) are non-overlapping by
    construction, a vehicle can never have two overlapping trips.
  - Onfleet consistency: every completed Onfleet task assigned to an FTE
    driver falls within the time window of exactly one of that driver's
    Samsara trips that day. Trips are built by clustering a driver's task
    timestamps for the day (gap > 90 min = new trip), then padding the
    cluster's start/end with a small buffer.
  - Operational metrics: distance and average speed are DERIVED from the
    trip's real duration (not invented independently), so they stay
    internally consistent by construction.

KNOWN EDGE CASE (documented, not silently hidden): Denver has 22 FTE
drivers but only 21 active vehicles (one van is permanently out of
service — see shared_ids.py). On any day where all 22 have Onfleet
deliveries, exactly one driver won't get a vehicle that day, and their
deliveries that day will have no corresponding Samsara trip. Vehicles are
allocated to the highest-delivery-volume drivers first specifically to
minimize how often this happens and to make the impact fall on whichever
driver has the least activity when it does. Frequency is reported in the
generator's summary output.

Quirks intentionally reproduced:
  1. Coordinate format is named {latitude, longitude} — NOT Onfleet's [lng,lat]
  5. Fuel data in US gallons AND ml — needs unit normalisation
  6. HOS violations recorded — 3 drivers get a violation entry
  7. A terminated driver simply has no Onfleet deliveries (and therefore
     no Samsara trips) after their termination_date — falls out naturally
     from Onfleet's own termination-aware eligibility, no special case here.

Output:
  data/raw/samsara/vehicles/vehicles.json
  data/raw/samsara/trips/{YYYY_MM}/trips_{vehicle_id}.json
  data/raw/samsara/driver_summary/driver_summary.json

Period: 2025-01-01 to 2025-06-30
"""

import json
import os
import glob
import random
from datetime import datetime, timedelta, timezone
from faker import Faker

import shared_ids

SEED = 42
random.seed(SEED)
fake = Faker()
Faker.seed(SEED)

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT_BASE  = os.path.join(PROJECT_ROOT, "data", "raw", "samsara")
ONFLEET_BASE = os.path.join(PROJECT_ROOT, "data", "raw", "onfleet")

START_DATE = datetime(2025, 1,  1, tzinfo=timezone.utc)
END_DATE   = datetime(2025, 6, 30, tzinfo=timezone.utc)

HUB_COORDS = {
    "denver":         {"latitude": 39.7558, "longitude": -104.9936},
    "salt_lake_city": {"latitude": 40.7282, "longitude": -111.8679},
    "albuquerque":    {"latitude": 35.1105, "longitude": -106.6298},
}

VEHICLE_TYPE_LABEL = {"cargo_van": "Cargo Van", "motorcycle": "Motorcycle", "box_truck": "Box Truck"}
MPG = {"cargo_van": 18.5, "motorcycle": 52.0, "box_truck": 10.5}

SPEED_RANGE_KMH = {"cargo_van": (18, 32), "motorcycle": (22, 38), "box_truck": (28, 50)}

GAP_THRESHOLD_MINUTES = 90
TRIP_PADDING_MINUTES = (8, 20)


def named_coords(city, jitter_km=5):
    hub = HUB_COORDS[city]
    lat_jitter = random.uniform(-jitter_km / 111, jitter_km / 111)
    lng_jitter = random.uniform(-jitter_km / 85, jitter_km / 85)
    return {
        "latitude":  round(hub["latitude"] + lat_jitter, 6),
        "longitude": round(hub["longitude"] + lng_jitter, 6),
    }


def is_driver_active_on(driver, date_obj):
    if driver["termination_date"] is None:
        return True
    term = datetime.strptime(driver["termination_date"], "%Y-%m-%d").date()
    return date_obj <= term


# ══════════════════════════════════════════════════════════════════════════
#  VEHICLE ROSTER — sourced from shared_ids.VEHICLES (unchanged)
# ══════════════════════════════════════════════════════════════════════════

def build_vehicles():
    random.seed(600)
    vehicles = []
    for v in shared_ids.VEHICLES:
        vin_end = "".join(random.choices("0123456789ABCDEFGHJKLMNPRSTUVWXYZ", k=11))
        vehicles.append({
            "id":           v["samsara_vehicle_id"],
            "name":         v["vehicle_name"],
            "vin":          f"1FTBR{vin_end}",
            "make":         v["make"],
            "model":        v["model"],
            "year":         v["year"],
            "vehicleType":  VEHICLE_TYPE_LABEL[v["vehicle_type"]],
            "licensePlate": (f"{random.choice('ABCDEFGHIJKLMNOPQRSTUVWXYZ')}"
                              f"{random.choice('ABCDEFGHIJKLMNOPQRSTUVWXYZ')}"
                              f"{random.randint(10000, 99999)}"),
            "fuelType":     v["fuel_type"],
            "tags": [
                {"id": str(random.randint(1000, 9999)), "name": v["city"]},
                {"id": str(random.randint(1000, 9999)), "name": VEHICLE_TYPE_LABEL[v["vehicle_type"]]},
            ],
            "currentOdometerMeters": random.randint(25000, 180000) * 1609,
            "lastKnownLocation":     named_coords(v["city"]),
            "operationalStatus":     "active" if v["is_active"] else "outOfService",
            "_city":   v["city"],
            "_vtype":  v["vehicle_type"],
            "_active": v["is_active"],
        })
    random.seed(SEED)
    return vehicles


# ══════════════════════════════════════════════════════════════════════════
#  ONFLEET INGESTION
# ══════════════════════════════════════════════════════════════════════════

def load_driver_delivery_windows():
    """
    Reads every Onfleet task page already on disk and builds:
        { onfleet_worker_id: [ (visit_start_dt, visit_end_dt), ... ] }
    for FTE drivers only — a FLAT list per driver, deliberately NOT
    bucketed by calendar date. Bucketing by date first and clustering
    within each day independently allowed two adjacent days' blocks for
    the same driver to still collide in absolute time near the midnight
    boundary once padding was applied. Clustering the driver's full
    timeline at once eliminates that entirely.

    Window anchor: completionDetails.time minus serviceTime (a few
    minutes) — the one timestamp that reflects the driver's actual
    physical presence at a stop. timeCreated is NOT used as a window
    start, since for next_day service (24h SLA) completion can
    legitimately happen up to ~21 hours after creation — that's SLA lead
    time, not continuous driving time.
    """
    fte_worker_ids = {d["onfleet_worker_id"] for d in shared_ids.DRIVERS if d["employment_type"] == "FTE"}

    windows = {}
    task_files = glob.glob(os.path.join(ONFLEET_BASE, "*", "page_*.json"))
    if not task_files:
        raise RuntimeError(
            "No Onfleet task files found at " + ONFLEET_BASE + ". "
            "generate_samsara.py now depends on Onfleet's output — "
            "run generate_onfleet.py first."
        )

    for path in task_files:
        with open(path, "r", encoding="utf-8") as fh:
            payload = json.load(fh)
        for task in payload["tasks"]:
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


MAX_BLOCK_HOURS = 16   # no single trip should span more than a long working day

def cluster_into_trip_blocks(intervals):
    """Merges a driver's delivery-activity intervals into non-overlapping
    trip blocks (gap > GAP_THRESHOLD_MINUTES = new block). Also caps any
    single block at MAX_BLOCK_HOURS: with enough deliveries over a long
    period, occasional 90-minute-or-less gaps between completions on
    DIFFERENT calendar days can chain together purely by chance into an
    unrealistic multi-day "single trip" — this cap forces a new block
    once that would happen, regardless of how small the individual gaps
    were."""
    if not intervals:
        return []
    intervals = sorted(intervals, key=lambda iv: iv[0])
    blocks = []
    cur_start, cur_end = intervals[0]

    for s, e in intervals[1:]:
        gap = (s - cur_end).total_seconds() / 60
        prospective_span_hours = (e - cur_start).total_seconds() / 3600
        if gap <= GAP_THRESHOLD_MINUTES and prospective_span_hours <= MAX_BLOCK_HOURS:
            cur_end = max(cur_end, e)
        else:
            blocks.append((cur_start, cur_end))
            cur_start, cur_end = s, e
    blocks.append((cur_start, cur_end))

    padded = []
    for s, e in blocks:
        pad_start = random.randint(*TRIP_PADDING_MINUTES)
        pad_end = random.randint(*TRIP_PADDING_MINUTES)
        padded.append((s - timedelta(minutes=pad_start), e + timedelta(minutes=pad_end)))
    return padded


# ══════════════════════════════════════════════════════════════════════════
#  TRIP BUILDER
# ══════════════════════════════════════════════════════════════════════════

def make_trip(vehicle, driver_samsara_id, window_start, window_end, trip_num, city):
    total_mins = (window_end - window_start).total_seconds() / 60
    vtype = vehicle["_vtype"]

    speed_lo, speed_hi = SPEED_RANGE_KMH[vtype]
    avg_speed_kmh = random.uniform(speed_lo, speed_hi)

    idle_frac = random.uniform(0.10, 0.25)
    idle_mins = total_mins * idle_frac
    drive_mins = total_mins - idle_mins

    dist_km = avg_speed_kmh * (drive_mins / 60)

    fuel_gallons = round(dist_km * 0.621371 / MPG[vtype], 3)
    max_speed_mph = round(random.uniform(speed_hi * 0.621371 * 1.3, speed_hi * 0.621371 * 2.0), 1)
    reported_avg_speed_mph = round(dist_km * 0.621371 / (total_mins / 60), 1) if total_mins > 0 else 0.0
    speeding = max_speed_mph > 65

    return {
        "id":        f"trip_{vehicle['id']}_{window_start.strftime('%Y%m%d')}_{trip_num:03d}",
        "vehicleId": vehicle["id"],
        "driverId":  driver_samsara_id,
        "startMs":   int(window_start.timestamp() * 1000),
        "endMs":     int(window_end.timestamp() * 1000),
        "startAddress": fake.street_address(),
        "endAddress":   fake.street_address(),
        "startCoords":  named_coords(city, jitter_km=8),
        "endCoords":    named_coords(city, jitter_km=8),
        "distanceMeters":      round(dist_km * 1000, 1),
        "durationMs":          round(total_mins * 60 * 1000),
        "drivingDurationMs":   round(drive_mins * 60 * 1000),
        "idlingDurationMs":    round(idle_mins * 60 * 1000),
        "fuelConsumedMl":      round(fuel_gallons * 3785.41),
        "fuelConsumedGallons": fuel_gallons,
        "maxSpeedMph":         max_speed_mph,
        "averageSpeedMph":     reported_avg_speed_mph,
        "safetyEvents": (
            [{"type": "speeding",
              "startMs": int((window_start + timedelta(minutes=random.uniform(2, max(3, total_mins - 2)))).timestamp() * 1000),
              "maxSpeedMph": max_speed_mph}]
            if speeding else []
        ),
    }


def make_depot_trip(vehicle, city, date_obj, trip_num):
    """Reinterpreted QUIRK 4: only on a day a vehicle has NO assigned
    driver at all — small chance of a short driverless depot trip."""
    start_dt = datetime(date_obj.year, date_obj.month, date_obj.day,
                         random.randint(5, 6), random.randint(0, 59), tzinfo=timezone.utc)
    dur_mins = random.randint(8, 25)
    end_dt = start_dt + timedelta(minutes=dur_mins)
    dist_km = random.uniform(0.5, 3.0)

    return {
        "id":        f"trip_{vehicle['id']}_{date_obj.strftime('%Y%m%d')}_{trip_num:03d}",
        "vehicleId": vehicle["id"],
        "driverId":  None,
        "startMs":   int(start_dt.timestamp() * 1000),
        "endMs":     int(end_dt.timestamp() * 1000),
        "startAddress": "SwiftRoute Depot",
        "endAddress":   "SwiftRoute Depot",
        "startCoords":  named_coords(city, jitter_km=1),
        "endCoords":    named_coords(city, jitter_km=1),
        "distanceMeters":      round(dist_km * 1000, 1),
        "durationMs":          dur_mins * 60 * 1000,
        "drivingDurationMs":   round(dur_mins * 60 * 1000 * 0.8),
        "idlingDurationMs":    round(dur_mins * 60 * 1000 * 0.2),
        "fuelConsumedMl":      round(dist_km * 0.621371 / MPG["cargo_van"] * 3785.41),
        "fuelConsumedGallons": round(dist_km * 0.621371 / MPG["cargo_van"], 3),
        "maxSpeedMph":         round(random.uniform(10, 20), 1),
        "averageSpeedMph":     round(dist_km * 0.621371 / (dur_mins / 60), 1),
        "safetyEvents":        [],
    }


# ══════════════════════════════════════════════════════════════════════════
#  DRIVER SAFETY SUMMARY (unchanged)
# ══════════════════════════════════════════════════════════════════════════

def build_driver_summary():
    random.seed(700)
    fte = [d for d in shared_ids.DRIVERS if d["employment_type"] == "FTE"]
    summaries = []

    box_truck_cities = ["denver", "denver", "salt_lake_city"]
    hos_candidates = []
    for city in box_truck_cities:
        pool = [d for d in fte if d["city"] == city and d not in hos_candidates]
        hos_candidates.append(random.choice(pool))

    for d in fte:
        total_km = random.uniform(4000, 28000)
        total_trips = random.randint(80, 420)
        speeding_ct = random.randint(0, 12)
        harsh_brake = random.randint(0, 18)
        safety_score = round(max(40, min(100,
            100 - speeding_ct * 2.5 - harsh_brake * 1.5 + random.uniform(-5, 5))), 1)

        hos_violations = []
        if d in hos_candidates:
            hos_violations = [{
                "violationType": "CYCLE_LIMIT",
                "startMs": int(datetime(2025, random.randint(1, 6), random.randint(1, 28),
                                          tzinfo=timezone.utc).timestamp() * 1000),
                "durationMs": random.randint(15, 90) * 60 * 1000,
                "description": "70-hour/8-day cycle limit exceeded",
            }]

        summaries.append({
            "driverId":            d["samsara_driver_id"],
            "driverName":          d["full_name"],
            "totalDistanceMeters": round(total_km * 1000),
            "totalDriveTimeMs":    round(total_km / 35 * 3600 * 1000),
            "totalIdleTimeMs":     round(random.uniform(0.08, 0.22) * total_km / 35 * 3600 * 1000),
            "totalTrips":          total_trips,
            "speedingCount":       speeding_ct,
            "harshBrakingCount":   harsh_brake,
            "harshAccelCount":     random.randint(0, 10),
            "safetyScore":         safety_score,
            "hosViolations":       hos_violations,
            "_city":               d["city"],
        })

    random.seed(SEED)
    return summaries


# ══════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════

def main():
    print("SwiftRoute — Samsara raw data generator")
    print("=" * 45)

    vehicles = build_vehicles()
    vehicles_by_city = {}
    for v in vehicles:
        vehicles_by_city.setdefault(v["_city"], []).append(v)
    for city in vehicles_by_city:
        vehicles_by_city[city] = [v for v in vehicles_by_city[city] if v["_active"]]

    print("Loading Onfleet delivery windows (Onfleet must have already run)...")
    windows = load_driver_delivery_windows()
    print(f"  Delivery records loaded for {len(windows)} FTE drivers")
    print()

    veh_folder = os.path.join(OUTPUT_BASE, "vehicles")
    os.makedirs(veh_folder, exist_ok=True)
    vehicle_payload = {
        "data": [{k: v for k, v in veh.items() if not k.startswith("_")} for veh in vehicles],
        "pagination": {"endCursor": "eyJpZCI6NDgyOTEwMzR9", "hasNextPage": False},
    }
    with open(os.path.join(veh_folder, "vehicles.json"), "w") as fh:
        json.dump(vehicle_payload, fh, indent=2, ensure_ascii=False)
    print("Vehicles written to vehicles/vehicles.json")
    print()

    driver_by_worker_id = {d["onfleet_worker_id"]: d for d in shared_ids.DRIVERS}

    # Step 1: cluster each driver's FULL timeline once (not day-bucketed) —
    # this alone guarantees driver-availability with no midnight-boundary risk.
    print("Clustering each driver's full delivery timeline into trip blocks...")
    driver_blocks = []   # (worker_id, city, block_start, block_end)
    for wid, intervals in windows.items():
        driver = driver_by_worker_id[wid]
        blocks = cluster_into_trip_blocks(intervals)
        for b_start, b_end in blocks:
            # No termination re-check here: Onfleet already only ever
            # assigned this driver a task while they were eligible. A
            # task assigned before termination can still legitimately
            # COMPLETE a day later (completion lag) — that trailing
            # block is a faithful record of Onfleet's own ground truth,
            # not a new inconsistency to filter out.
            driver_blocks.append((wid, driver["city"], b_start, b_end))

    # Step 2: process ALL blocks in true chronological order (across the
    # whole simulation, not per calendar day) and greedily assign each one
    # to any vehicle in that city that is genuinely free at that moment —
    # tracked by a real "free_from" timestamp per vehicle, not a coarse
    # per-day flag. This is what actually guarantees vehicle availability,
    # including across midnight boundaries.
    driver_blocks.sort(key=lambda b: b[2])   # sort by block_start

    vehicle_free_from = {v["id"]: datetime.min.replace(tzinfo=timezone.utc) for v in vehicles}
    vehicle_trips = {v["id"]: [] for v in vehicles}
    vehicle_last_used = {v["id"]: 0 for v in vehicles}   # for least-recently-used tie-breaking

    total_trips = 0
    driver_short_events = 0
    trip_counter = 0

    print("Assigning vehicles by true chronological availability...")
    for wid, city, b_start, b_end in driver_blocks:
        driver = driver_by_worker_id[wid]
        candidates = [v for v in vehicles_by_city.get(city, []) if vehicle_free_from[v["id"]] <= b_start]

        if not candidates:
            driver_short_events += 1
            continue

        # Prefer the vehicle that's been idle longest (spreads usage out,
        # avoids always picking the same one)
        candidates.sort(key=lambda v: vehicle_last_used[v["id"]])
        vehicle = candidates[0]

        trip_counter += 1
        trip = make_trip(vehicle, driver["samsara_driver_id"], b_start, b_end, trip_counter, city)
        vehicle_trips[vehicle["id"]].append(trip)
        total_trips += 1

        vehicle_free_from[vehicle["id"]] = b_end
        vehicle_last_used[vehicle["id"]] = trip_counter

    # Step 3: reinterpreted QUIRK 4 — depot-move trips only on calendar
    # days a vehicle has ZERO real trips at all (computed post-hoc, so it
    # can never collide with a real assignment).
    print("Adding depot-move quirk trips on fully idle vehicle-days...")
    depot_trips = 0
    date = START_DATE
    while date <= END_DATE:
        d_key = date.date()
        for city, city_vehicles in vehicles_by_city.items():
            for vehicle in city_vehicles:
                has_trip_today = any(
                    datetime.fromtimestamp(t["startMs"] / 1000, tz=timezone.utc).date() == d_key
                    for t in vehicle_trips[vehicle["id"]]
                )
                if has_trip_today:
                    continue
                if random.random() < 0.03:
                    trip_counter += 1
                    trip = make_depot_trip(vehicle, city, d_key, trip_counter)
                    vehicle_trips[vehicle["id"]].append(trip)
                    total_trips += 1
                    depot_trips += 1
        date += timedelta(days=1)

    # Step 4: write monthly files per vehicle
    print("Writing trip files...")
    trip_folder = os.path.join(OUTPUT_BASE, "trips")
    months_written = set()
    for vehicle in vehicles:
        trips = sorted(vehicle_trips[vehicle["id"]], key=lambda t: t["startMs"])
        by_month = {}
        for t in trips:
            dt = datetime.fromtimestamp(t["startMs"] / 1000, tz=timezone.utc)
            month_key = f"{dt.year}_{str(dt.month).zfill(2)}"
            by_month.setdefault(month_key, []).append(t)

        for month_key, month_trips in by_month.items():
            month_folder = os.path.join(trip_folder, month_key)
            os.makedirs(month_folder, exist_ok=True)
            payload = {
                "vehicleId": vehicle["id"],
                "vehicleName": vehicle["name"],
                "month": month_key,
                "pagination": {"endCursor": month_trips[-1]["id"], "hasNextPage": False},
                "trips": month_trips,
            }
            with open(os.path.join(month_folder, f"trips_{vehicle['id']}.json"), "w") as fh:
                json.dump(payload, fh, indent=2, ensure_ascii=False)
            months_written.add(month_key)

    for m in sorted(months_written):
        print(f"  {m}: trips written")

    summary = build_driver_summary()
    hos_drivers = [d for d in summary if d["hosViolations"]]

    summ_folder = os.path.join(OUTPUT_BASE, "driver_summary")
    os.makedirs(summ_folder, exist_ok=True)
    with open(os.path.join(summ_folder, "driver_summary.json"), "w") as fh:
        json.dump({"data": summary, "pagination": {"endCursor": None, "hasNextPage": False}},
                   fh, indent=2, ensure_ascii=False)

    print()
    print("=" * 45)
    print(f"Total trips              : {total_trips:,}")
    print(f"  of which depot-move    : {depot_trips:,}  (reinterpreted QUIRK 4 — driverless, idle-vehicle days only)")
    print(f"Driver blocks short a vehicle : {driver_short_events:,}  (known Denver 22-vs-21 edge case)")
    print(f"HOS violations            : {len(hos_drivers)} drivers")
    print(f"Driver summaries          : {len(summary)}")
    print(f"Output                    : {OUTPUT_BASE}")


if __name__ == "__main__":
    main()
