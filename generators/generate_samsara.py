"""
generators/generate_samsara.py

Generates synthetic Samsara Fleet API responses for SwiftRoute Logistics.
Imports VEHICLES and DRIVERS from shared_ids.py (written by
generate_shared_ids.py, which must run first) — shared_ids.py is
authoritative for vehicle identity, driver identity, and vehicle
operational status (active / out-of-service). This generator only adds
Samsara-specific telemetry fields on top of that canonical data.

DESIGN NOTE — vehicles and drivers are separate asset pools, not a fixed
1:1 pairing. Any FTE driver in a given city is eligible to drive any
vehicle in that city on a given day (matches real fleet operations —
drivers rotate vehicles; the vehicle keeps its own permanent attributes
like make/model regardless of who's driving it that day). Only FTE
drivers appear here — IC drivers use their own personal vehicles, which
a company fleet-telematics platform like Samsara would never track.

Mirrors the real Samsara v1 API JSON structure from three endpoints:
  GET /fleet/vehicles                 → vehicle roster
  GET /fleet/trips?vehicleId=...      → GPS trip history per vehicle
  GET /fleet/drivers/summary          → driver safety scores and HOS

Quirks intentionally reproduced:
  1. Coordinate format is named {latitude, longitude} — NOT Onfleet's [lng,lat]
  2. Trip vehicleId has no native link to Onfleet — requires mapping table
     (in this rebuild, the link DOES exist via shared_ids, but no such
     table exists inside Samsara's own JSON — a practitioner opening only
     this file still has to go find it)
  3. Idle time included in trip duration — inflates apparent route time
  4. Some trips have no driverId (vehicle moved without driver login)
  5. Fuel data in US gallons AND ml — needs unit normalisation
  6. HOS violations recorded — 3 box truck drivers have entries
  7. A terminated driver simply drops out of the eligible-driver pool
     after their termination_date — since driver-vehicle pairing is
     decided fresh per vehicle per day, this falls out naturally rather
     than needing special-case handling.

Output:
  source_data/raw/samsara/vehicles/vehicles.json
  source_data/raw/samsara/trips/{YYYY_MM}/trips_{vehicle_id}.json
  source_data/raw/samsara/driver_summary/driver_summary.json

Period: 2025-01-01 to 2025-06-30
"""

import json
import os
import random
from datetime import datetime, timedelta, timezone
from faker import Faker

import shared_ids

SEED = 42
random.seed(SEED)
fake = Faker()
Faker.seed(SEED)

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT_BASE  = os.path.join(PROJECT_ROOT, "source_data", "raw", "samsara")

START_DATE = datetime(2025, 1,  1, tzinfo=timezone.utc)
END_DATE   = datetime(2025, 6, 30, tzinfo=timezone.utc)

HUB_COORDS = {
    "denver":         {"latitude": 39.7558, "longitude": -104.9936},
    "salt_lake_city": {"latitude": 40.7282, "longitude": -111.8679},
    "albuquerque":    {"latitude": 35.1105, "longitude": -106.6298},
}

VEHICLE_TYPE_LABEL = {"cargo_van": "Cargo Van", "motorcycle": "Motorcycle", "box_truck": "Box Truck"}
MPG = {"cargo_van": 18.5, "motorcycle": 52.0, "box_truck": 10.5}


def rfc3339(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def named_coords(city, jitter_km=5):
    """QUIRK 1: named {latitude, longitude}, opposite of Onfleet's [lng, lat]."""
    hub = HUB_COORDS[city]
    lat_jitter = random.uniform(-jitter_km / 111, jitter_km / 111)
    lng_jitter = random.uniform(-jitter_km / 85, jitter_km / 85)
    return {
        "latitude":  round(hub["latitude"] + lat_jitter, 6),
        "longitude": round(hub["longitude"] + lng_jitter, 6),
    }


# ══════════════════════════════════════════════════════════════════════════
#  DRIVER LOOKUP — resolve each vehicle's assigned driver from shared_ids
# ══════════════════════════════════════════════════════════════════════════

def driver_lookup_by_gusto_uuid():
    return {d["gusto_uuid"]: d for d in shared_ids.DRIVERS}


def fte_drivers_by_city():
    """Only FTE drivers are Samsara-eligible — IC drivers use their own
    personal vehicles, invisible to a company fleet-telematics platform."""
    pool = {}
    for d in shared_ids.DRIVERS:
        if d["employment_type"] != "FTE":
            continue
        pool.setdefault(d["city"], []).append(d)
    return pool


def is_driver_active_on(driver, date_obj):
    if driver["termination_date"] is None:
        return True
    term = datetime.strptime(driver["termination_date"], "%Y-%m-%d").date()
    return date_obj <= term


# ══════════════════════════════════════════════════════════════════════════
#  VEHICLE ROSTER — sourced from shared_ids.VEHICLES
# ══════════════════════════════════════════════════════════════════════════

def build_vehicles():
    """
    Takes the canonical shared_ids.VEHICLES list (identity, city, type,
    is_active — already decided, authoritative) and enriches each record
    with Samsara-only telemetry fields (VIN, license plate, odometer,
    tags, last known location).

    QUIRK 2: Samsara's own JSON carries no explicit reference back to
    Onfleet — the fact that this generator internally knows the mapping
    (via shared_ids) doesn't mean the *output file* exposes it.
    """
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
            "_ods_note": (
                "QUIRK 2: this file has no column linking back to Onfleet. "
                "The vehicle<->driver identity is only resolvable via "
                "shared_ids.py in the ODS reference layer."
            ),
        })

    random.seed(SEED)
    return vehicles


# ══════════════════════════════════════════════════════════════════════════
#  TRIP GENERATOR
# ══════════════════════════════════════════════════════════════════════════

def make_trip(date, vehicle, driver, trip_num):
    """
    QUIRK 3: idlingDurationMs is folded into durationMs.
    QUIRK 4: ~5% of trips have no driverId regardless of anything else
    (nobody logged into the Samsara driver app that trip).
    QUIRK 7: if no eligible driver exists at all for this vehicle/day
    (e.g. every driver in that city already terminated — edge case),
    driverId is null by construction, not a special case.
    """
    city  = vehicle["_city"]
    vtype = vehicle["_vtype"]

    start_hour = random.randint(6, 18)
    start_min  = random.randint(0, 59)
    start_dt   = date.replace(hour=start_hour, minute=start_min, second=0, microsecond=0)

    if vtype == "motorcycle":
        dist_km, speed_avg = random.uniform(2, 25), random.uniform(22, 38)
    elif vtype == "cargo_van":
        dist_km, speed_avg = random.uniform(5, 85), random.uniform(18, 32)
    else:
        dist_km, speed_avg = random.uniform(30, 220), random.uniform(28, 55)

    drive_mins = dist_km / speed_avg * 60
    idle_mins  = random.uniform(3, drive_mins * 0.25)
    total_mins = drive_mins + idle_mins
    end_dt = start_dt + timedelta(minutes=total_mins)

    day_end = date.replace(hour=21, minute=0, second=0, microsecond=0)
    if end_dt > day_end:
        end_dt = day_end
        total_mins = (end_dt - start_dt).total_seconds() / 60
        idle_mins = min(idle_mins, total_mins * 0.2)
        drive_mins = total_mins - idle_mins
        dist_km = drive_mins / 60 * speed_avg

    fuel_gallons = round(dist_km * 0.621371 / MPG[vtype], 3)
    max_speed_mph = round(random.uniform(28, 72), 1)
    speeding = max_speed_mph > 65

    random_no_login = random.random() < 0.05                       # QUIRK 4
    active_driver = None if (driver is None or random_no_login) else driver["samsara_driver_id"]

    return {
        "id":        f"trip_{vehicle['id']}_{date.strftime('%Y%m%d')}_{trip_num:03d}",
        "vehicleId": vehicle["id"],
        "driverId":  active_driver,
        "startMs":   int(start_dt.timestamp() * 1000),
        "endMs":     int(end_dt.timestamp() * 1000),
        "startAddress": fake.street_address(),
        "endAddress":   fake.street_address(),
        "startCoords":  named_coords(city, jitter_km=8),   # QUIRK 1
        "endCoords":    named_coords(city, jitter_km=8),
        "distanceMeters":      round(dist_km * 1000, 1),
        "durationMs":          round(total_mins * 60 * 1000),
        "drivingDurationMs":   round(drive_mins * 60 * 1000),
        "idlingDurationMs":    round(idle_mins * 60 * 1000),        # QUIRK 3
        "fuelConsumedMl":      round(fuel_gallons * 3785.41),       # QUIRK 5
        "fuelConsumedGallons": fuel_gallons,                        # QUIRK 5
        "maxSpeedMph":         max_speed_mph,
        "averageSpeedMph":     round(dist_km * 0.621371 / (total_mins / 60), 1),
        "safetyEvents": (
            [{"type": "speeding",
              "startMs": int((start_dt + timedelta(minutes=random.randint(2, max(3, int(total_mins) - 2)))).timestamp() * 1000),
              "maxSpeedMph": max_speed_mph}]
            if speeding else []
        ),
    }


# ══════════════════════════════════════════════════════════════════════════
#  DRIVER SAFETY SUMMARY
# ══════════════════════════════════════════════════════════════════════════

def build_driver_summary():
    """
    One record per FTE driver (not per vehicle — drivers rotate across
    vehicles, so the summary endpoint aggregates by driver, which is
    also how Samsara's real /fleet/drivers/summary endpoint works).

    QUIRK 6: exactly 3 drivers get an HOS violation, standing in for the
    3 box-truck-capable drivers in the fleet (Denver x2, SLC x1 — the
    3 box trucks in the doc's vehicle mix). Since vehicle assignment is
    now dynamic rather than fixed, we pick 3 FTE drivers from the cities
    that actually operate a box truck (Denver, SLC) to carry the
    violation, standing in for "drove a box truck shift that triggered
    an HOS event" rather than a permanent box-truck-driver role.
    """
    random.seed(700)
    fte = [d for d in shared_ids.DRIVERS if d["employment_type"] == "FTE"]
    summaries = []

    box_truck_cities = ["denver", "denver", "salt_lake_city"]  # 2 DEN + 1 SLC box trucks
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
            "_ods_note": (
                "driverId is Samsara-assigned and has no native link to the "
                "Gusto employee UUID or the Onfleet worker ID inside this "
                "file. The join must happen via shared_ids in the ODS."
            ),
        })

    random.seed(SEED)
    return summaries


# ══════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════

def main():
    print("SwiftRoute — Samsara raw data generator")
    print("=" * 45)

    by_uuid = driver_lookup_by_gusto_uuid()
    vehicles = build_vehicles()
    active   = [v for v in vehicles if v["_active"]]
    offroad  = [v for v in vehicles if not v["_active"]]

    print(f"Vehicles total : {len(vehicles)}")
    print(f"  Active       : {len(active)}")
    if offroad:
        print(f"  Off-road     : {len(offroad)}  <- {offroad[0]['name']} (from shared_ids)")
    print()

    veh_folder = os.path.join(OUTPUT_BASE, "vehicles")
    os.makedirs(veh_folder, exist_ok=True)
    vehicle_payload = {
        "data": [{k: v_ for k, v_ in v.items() if not k.startswith("_")} for v in vehicles],
        "pagination": {"endCursor": "eyJpZCI6NDgyOTEwMzR9", "hasNextPage": False},
    }
    with open(os.path.join(veh_folder, "vehicles.json"), "w") as fh:
        json.dump(vehicle_payload, fh, indent=2, ensure_ascii=False)
    print("Vehicles written to vehicles/vehicles.json")
    print()

    print("Generating trips...")
    trip_folder = os.path.join(OUTPUT_BASE, "trips")
    fte_pool = fte_drivers_by_city()
    total_trips = 0
    no_driver_ct = 0
    speeding_ct = 0
    no_eligible_driver_days = 0

    date = START_DATE
    while date <= END_DATE:
        month_key = f"{date.year}_{str(date.month).zfill(2)}"
        month_folder = os.path.join(trip_folder, month_key)
        os.makedirs(month_folder, exist_ok=True)
        month_start = date
        vehicle_month_trips = {v["id"]: [] for v in active}

        while date <= END_DATE and date.month == month_start.month:
            is_weekend = date.weekday() >= 5
            for v in active:
                if v["_vtype"] == "motorcycle" and date.weekday() == 6:
                    continue
                if v["_vtype"] == "box_truck" and is_weekend and random.random() < 0.7:
                    continue

                if v["_vtype"] == "motorcycle":
                    n_trips = random.randint(6, 18)
                elif v["_vtype"] == "cargo_van":
                    n_trips = random.randint(1, 4) if is_weekend else random.randint(2, 6)
                else:
                    n_trips = 1

                eligible = [d for d in fte_pool.get(v["_city"], []) if is_driver_active_on(d, date.date())]
                driver_for_day = random.choice(eligible) if eligible else None
                if driver_for_day is None:
                    no_eligible_driver_days += 1

                for t in range(n_trips):
                    trip = make_trip(date, v, driver_for_day, t + 1)
                    vehicle_month_trips[v["id"]].append(trip)
                    total_trips += 1
                    if trip["driverId"] is None:
                        no_driver_ct += 1
                    if trip["safetyEvents"]:
                        speeding_ct += 1

            date += timedelta(days=1)

        for v in active:
            trips = vehicle_month_trips[v["id"]]
            if not trips:
                continue
            payload = {
                "vehicleId": v["id"],
                "vehicleName": v["name"],
                "month": month_key,
                "pagination": {"endCursor": trips[-1]["id"], "hasNextPage": False},
                "trips": trips,
            }
            with open(os.path.join(month_folder, f"trips_{v['id']}.json"), "w") as fh:
                json.dump(payload, fh, indent=2, ensure_ascii=False)

        print(f"  {month_key}: trips written for {len(active)} vehicles")

    summary = build_driver_summary()
    hos_drivers = [d for d in summary if d["hosViolations"]]

    summ_folder = os.path.join(OUTPUT_BASE, "driver_summary")
    os.makedirs(summ_folder, exist_ok=True)
    with open(os.path.join(summ_folder, "driver_summary.json"), "w") as fh:
        json.dump({"data": summary, "pagination": {"endCursor": None, "hasNextPage": False}},
                   fh, indent=2, ensure_ascii=False)

    print()
    print("=" * 45)
    print(f"Total trips           : {total_trips:,}")
    print(f"No-driver trips       : {no_driver_ct:,}  ← QUIRK 4")
    print(f"Vehicle-days with zero eligible drivers : {no_eligible_driver_days:,}  ← QUIRK 7")
    print(f"Speeding events       : {speeding_ct:,}")
    print(f"HOS violations        : {len(hos_drivers)} drivers  ← QUIRK 6")
    print(f"Driver summaries      : {len(summary)}")
    print(f"Output                : {OUTPUT_BASE}")


if __name__ == "__main__":
    main()