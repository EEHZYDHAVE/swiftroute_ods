"""
generators/generate_samsara.py

Generates synthetic Samsara Fleet API responses for SwiftRoute Logistics.
Mirrors the real Samsara v1 API JSON structure from three endpoints:

  GET /fleet/vehicles                 → vehicle roster
  GET /fleet/trips?vehicleId=...      → GPS trip history per vehicle
  GET /fleet/drivers/summary          → driver safety scores and HOS

Samsara API characteristics:
  - Pagination via endCursor / hasNextPage (GraphQL-style cursor)
  - All timestamps are RFC3339 strings ("2025-01-15T14:32:11Z")
  - Location coordinates: {"latitude": ..., "longitude": ...} — named keys
    (opposite of Onfleet which uses positional [lng, lat] array)
  - Vehicle and driver IDs are numeric strings ("48291039")

Quirks intentionally reproduced:
  1. Coordinate format is named {latitude, longitude} — NOT Onfleet's [lng,lat]
  2. Trip vehicleId ≠ Onfleet vehicle reference — requires mapping table
  3. Idle time included in trip duration — inflates apparent route time
  4. Some trips have no driverId (vehicle moved without driver login)
  5. Fuel data in Samsara uses US gallons — needs unit normalisation
  6. HOS violations recorded — 3 box truck drivers have entries

Output:
  data/raw/samsara/vehicles/vehicles.json
  data/raw/samsara/trips/{YYYY_MM}/trips_{vehicle_id}.json
  data/raw/samsara/driver_summary/driver_summary.json

Period: 2025-01-01 to 2025-06-30
"""

import json
import os
import random
from datetime import datetime, timedelta, timezone
from faker import Faker

# ── Reproducibility ────────────────────────────────────────────────────────────
SEED = 42
random.seed(SEED)
fake = Faker()
Faker.seed(SEED)

# ── Paths ──────────────────────────────────────────────────────────────────────
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT_BASE  = os.path.join(PROJECT_ROOT, "data", "raw", "samsara")

# ── Simulation period ──────────────────────────────────────────────────────────
START_DATE = datetime(2025, 1,  1, tzinfo=timezone.utc)
END_DATE   = datetime(2025, 6, 30, tzinfo=timezone.utc)

# ── Fleet composition from operating document ──────────────────────────────────
FLEET = [
    # (city,           type,          count, samsara_type_tag)
    ("denver",         "cargo_van",   14,    "Cargo Van"),
    ("denver",         "motorcycle",   6,    "Motorcycle"),
    ("denver",         "box_truck",    2,    "Box Truck"),
    ("salt_lake_city", "cargo_van",    5,    "Cargo Van"),
    ("salt_lake_city", "motorcycle",   3,    "Motorcycle"),
    ("salt_lake_city", "box_truck",    1,    "Box Truck"),
    ("albuquerque",    "cargo_van",    3,    "Cargo Van"),
    ("albuquerque",    "motorcycle",   1,    "Motorcycle"),
]
# Total: 14+6+2+5+3+1+3+1 = 35 vehicles (1 van is off-road — see below)

# ── City hub coordinates (Samsara uses named {latitude, longitude}) ────────────
HUB_COORDS = {
    "denver":         {"latitude": 39.7558, "longitude": -104.9936},
    "salt_lake_city": {"latitude": 40.7282, "longitude": -111.8679},
    "albuquerque":    {"latitude": 35.1105, "longitude": -106.6298},
}

# ── Make/model pools by vehicle type ──────────────────────────────────────────
MAKES = {
    "cargo_van":  [("Ford","Transit 250"),("Mercedes","Sprinter 2500"),
                   ("RAM","ProMaster 2500")],
    "motorcycle": [("Honda","CB500F"),("Yamaha","MT-07"),("Kawasaki","Z650")],
    "box_truck":  [("Isuzu","NPR-HD"),("Hino","195")],
}

# ── Fuel efficiency (MPG) — used to calculate fuel consumption per trip ────────
MPG = {"cargo_van": 18.5, "motorcycle": 52.0, "box_truck": 10.5}

# ══════════════════════════════════════════════════════════════════════════════
#  HELPERS
# ══════════════════════════════════════════════════════════════════════════════

_vehicle_id_pool = iter(range(48291000, 48292000))
_driver_id_pool  = iter(range(22831000, 22832000))

def samsara_vehicle_id():
    return str(next(_vehicle_id_pool))

def samsara_driver_id():
    return str(next(_driver_id_pool))

def rfc3339(dt):
    """Samsara uses RFC3339 timestamps."""
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")

def named_coords(city, jitter_km=5):
    """
    QUIRK 1: Samsara uses named keys {latitude, longitude}.
    Onfleet uses positional array [longitude, latitude].
    The same physical location looks completely different between systems.
    """
    hub = HUB_COORDS[city]
    lat_jitter = random.uniform(-jitter_km/111, jitter_km/111)
    lng_jitter = random.uniform(-jitter_km/85,  jitter_km/85)
    return {
        "latitude":  round(hub["latitude"]  + lat_jitter, 6),
        "longitude": round(hub["longitude"] + lng_jitter, 6),
    }

# ══════════════════════════════════════════════════════════════════════════════
#  VEHICLE ROSTER
# ══════════════════════════════════════════════════════════════════════════════

def build_vehicles():
    """
    35 vehicles in the Samsara fleet.
    One Denver cargo van is flagged as 'off road' — it is in maintenance
    and generates no trips during the simulation period.

    QUIRK 2: Samsara vehicle IDs are numeric strings that bear no
    relationship to any ID in Onfleet. The mapping from Samsara vehicle
    to the 'vehicle_type' field on Onfleet tasks must be built manually
    in the ODS reference layer.
    """
    random.seed(600)
    vehicles = []

    for city, vtype, count, label in FLEET:
        make_pool = MAKES[vtype]
        for i in range(count):
            vid     = samsara_vehicle_id()
            make, model = random.choice(make_pool)
            year    = random.randint(2019, 2023)
            vin_end = "".join(random.choices("0123456789ABCDEFGHJKLMNPRSTUVWXYZ", k=11))

            is_offroad = (city == "denver" and vtype == "cargo_van" and i == 0)

            vehicles.append({
                "id":           vid,
                "name":         f"{city[:3].upper()}-{label[:3].upper()}-{str(i+1).zfill(2)}",
                "vin":          f"1FTBR{vin_end}",
                "make":         make,
                "model":        model,
                "year":         year,
                "vehicleType":  label,
                "licensePlate": f"{random.choice('ABCDEFGHIJKLMNOPQRSTUVWXYZ')}{random.choice('ABCDEFGHIJKLMNOPQRSTUVWXYZ')}{random.randint(10000,99999)}",
                "fuelType":     "gasoline" if vtype != "box_truck" else "diesel",
                "tags": [
                    {"id": str(random.randint(1000,9999)), "name": city},
                    {"id": str(random.randint(1000,9999)), "name": label},
                ],
                "currentOdometerMeters": random.randint(25000, 180000) * 1609,
                "lastKnownLocation": named_coords(city),
                "operationalStatus": "outOfService" if is_offroad else "active",
                "_city":   city,
                "_vtype":  vtype,
                "_active": not is_offroad,
                # QUIRK 2 note
                "_ods_note": (
                    "Samsara vehicle ID has no native link to Onfleet. "
                    "A ref_vehicle_mapping table in the ODS must join "
                    "Samsara vehicle ID to the vehicle_type metadata "
                    "on Onfleet tasks."
                ),
            })

    random.seed(SEED)
    return vehicles


# ══════════════════════════════════════════════════════════════════════════════
#  TRIP GENERATOR
# ══════════════════════════════════════════════════════════════════════════════

def make_trip(date, vehicle, driver_id, trip_num):
    """
    One Samsara trip = one continuous vehicle movement from engine-on
    to engine-off.

    QUIRK 3: distanceMeters / durationMs include idle time.
    A trip that drove 12km but sat in traffic for 20 minutes will show
    a longer duration than a pure-movement analysis would expect.
    The idle portion is in idlingDurationMs.

    QUIRK 4: Some trips have no driverId — the vehicle was moved by
    someone who did not log into the Samsara driver app (fuelling,
    maintenance, depot movement).
    """
    city  = vehicle["_city"]
    vtype = vehicle["_vtype"]

    # Trip start time — spread across the working day
    start_hour = random.randint(6, 18)
    start_min  = random.randint(0, 59)
    start_dt   = date.replace(hour=start_hour, minute=start_min,
                               second=0, microsecond=0)

    # Distance and duration based on vehicle type and city
    if vtype == "motorcycle":
        dist_km   = random.uniform(2, 25)
        speed_avg = random.uniform(22, 38)  # km/h including stops
    elif vtype == "cargo_van":
        dist_km   = random.uniform(5, 85)
        speed_avg = random.uniform(18, 32)
    else:  # box_truck
        dist_km   = random.uniform(30, 220)
        speed_avg = random.uniform(28, 55)

    drive_mins = dist_km / speed_avg * 60
    idle_mins  = random.uniform(3, drive_mins * 0.25)   # QUIRK 3
    total_mins = drive_mins + idle_mins

    end_dt = start_dt + timedelta(minutes=total_mins)

    # Clamp to same day
    day_end = date.replace(hour=21, minute=0, second=0, microsecond=0)
    if end_dt > day_end:
        end_dt    = day_end
        total_mins = (end_dt - start_dt).total_seconds() / 60
        idle_mins  = min(idle_mins, total_mins * 0.2)
        drive_mins = total_mins - idle_mins
        dist_km    = drive_mins / 60 * speed_avg

    # Fuel consumption in US gallons (QUIRK 5)
    fuel_gallons = round(dist_km * 0.621371 / MPG[vtype], 3)

    # Max speed with realistic distribution
    max_speed_mph = round(random.uniform(28, 72), 1)
    # Flag if over 65 mph (safety event territory)
    speeding = max_speed_mph > 65

    # QUIRK 4: ~5% of trips have no driver login
    no_driver_login = random.random() < 0.05
    active_driver   = None if no_driver_login else driver_id

    return {
        "id":        f"trip_{vehicle['id']}_{date.strftime('%Y%m%d')}_{trip_num:03d}",
        "vehicleId": vehicle["id"],
        "driverId":  active_driver,    # QUIRK 4: can be null
        "startMs":   int(start_dt.timestamp() * 1000),
        "endMs":     int(end_dt.timestamp() * 1000),
        "startLocation": named_coords(city, jitter_km=8),
        "endLocation":   named_coords(city, jitter_km=8),
        "startAddress":  fake.street_address(),
        "endAddress":    fake.street_address(),
        # QUIRK 1: named keys, NOT positional array like Onfleet
        "startCoords": named_coords(city, jitter_km=8),
        "endCoords":   named_coords(city, jitter_km=8),
        "distanceMeters":       round(dist_km * 1000, 1),
        "durationMs":           round(total_mins * 60 * 1000),
        "drivingDurationMs":    round(drive_mins * 60 * 1000),
        "idlingDurationMs":     round(idle_mins  * 60 * 1000),  # QUIRK 3
        "fuelConsumedMl":       round(fuel_gallons * 3785.41),  # QUIRK 5: gallons→ml
        "fuelConsumedGallons":  fuel_gallons,                   # QUIRK 5: raw gallons
        "maxSpeedMph":          max_speed_mph,
        "averageSpeedMph":      round(dist_km * 0.621371 / (total_mins / 60), 1),
        "safetyEvents": (
            [{"type": "speeding",
              "startMs": int((start_dt + timedelta(minutes=random.randint(2, max(3, int(total_mins)-2)))).timestamp()*1000),
              "maxSpeedMph": max_speed_mph}]
            if speeding else []
        ),
        "_no_driver_login": no_driver_login,  # for verification
        "_fuel_note": (
            "QUIRK 5: fuelConsumedGallons is in US gallons. "
            "Multiply by 3.785 for litres. "
            "Samsara does not link fuel to specific Onfleet tasks."
        ) if trip_num == 1 else "",
    }


# ══════════════════════════════════════════════════════════════════════════════
#  DRIVER SAFETY SUMMARY
# ══════════════════════════════════════════════════════════════════════════════

def build_driver_summary(vehicles):
    """
    Samsara's /fleet/drivers/summary endpoint returns aggregate safety
    metrics per driver for a requested time window.

    QUIRK 6: Three box truck drivers have HOS (Hours of Service)
    violation entries. HOS rules govern how long CDL drivers can work
    without mandatory rest. Violations are a regulatory risk item.
    """
    random.seed(700)

    drivers = []
    driver_counter = [0]

    box_truck_drivers = []
    regular_drivers   = []

    for v in vehicles:
        if not v["_active"]:
            continue
        did   = samsara_driver_id()
        vtype = v["_vtype"]

        total_km    = random.uniform(4000, 28000)
        total_trips = random.randint(80, 420)
        speeding_ct = random.randint(0, 12)
        harsh_brake = random.randint(0, 18)
        safety_score = round(max(40, min(100,
            100 - speeding_ct * 2.5 - harsh_brake * 1.5
            + random.uniform(-5, 5))), 1)

        hos_violations = []
        if vtype == "box_truck" and driver_counter[0] < 3:
            hos_violations = [
                {
                    "violationType":    "CYCLE_LIMIT",
                    "startMs":          int((datetime(2025, random.randint(1,6),
                                         random.randint(1,28), tzinfo=timezone.utc)
                                        ).timestamp() * 1000),
                    "durationMs":       random.randint(15, 90) * 60 * 1000,
                    "description":      "70-hour/8-day cycle limit exceeded",
                }
            ]
            driver_counter[0] += 1

        d = {
            "driverId":    did,
            "vehicleId":   v["id"],
            "driverName":  fake.name(),
            "totalDistanceMeters": round(total_km * 1000),
            "totalDriveTimeMs":    round(total_km / 35 * 3600 * 1000),
            "totalIdleTimeMs":     round(random.uniform(0.08, 0.22) * total_km / 35 * 3600 * 1000),
            "totalTrips":          total_trips,
            "speedingCount":       speeding_ct,
            "harshBrakingCount":   harsh_brake,
            "harshAccelCount":     random.randint(0, 10),
            "safetyScore":         safety_score,
            "hosViolations":       hos_violations,  # QUIRK 6
            "_vehicle_city":       v["_city"],
            "_vehicle_type":       vtype,
            "_ods_note": (
                "driverId is Samsara-assigned and has no native link "
                "to the Gusto employee UUID or the Onfleet worker ID. "
                "All three systems use different identifiers for the "
                "same person. A ref_driver_mapping table is required."
            ),
        }
        drivers.append(d)

    random.seed(SEED)
    return drivers


# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════

def main():
    print("SwiftRoute — Samsara raw data generator")
    print("=" * 45)

    vehicles = build_vehicles()
    active   = [v for v in vehicles if v["_active"]]
    offroad  = [v for v in vehicles if not v["_active"]]

    print(f"Vehicles total : {len(vehicles)}")
    print(f"  Active       : {len(active)}")
    print(f"  Off-road     : {len(offroad)}  <- {offroad[0]['name']} in maintenance")
    print()

    # ── Write vehicles ─────────────────────────────────────────────────────────
    veh_folder = os.path.join(OUTPUT_BASE, "vehicles")
    os.makedirs(veh_folder, exist_ok=True)

    # Samsara wraps vehicle list in a data envelope with cursor pagination
    vehicle_payload = {
        "data": vehicles,
        "pagination": {
            "endCursor":   "eyJpZCI6NDgyOTEwMzR9",
            "hasNextPage": False,
        },
    }
    with open(os.path.join(veh_folder, "vehicles.json"), "w") as fh:
        json.dump(vehicle_payload, fh, indent=2, ensure_ascii=False)
    print("Vehicles written to vehicles/vehicles.json")
    print()

    # ── Generate trips per vehicle per month ───────────────────────────────────
    print("Generating trips...")
    trip_folder = os.path.join(OUTPUT_BASE, "trips")
    total_trips  = 0
    no_driver_ct = 0
    speeding_ct  = 0

    # Assign a Samsara driver ID to each active vehicle
    vehicle_driver_map = {v["id"]: samsara_driver_id() for v in active}

    date = START_DATE
    while date <= END_DATE:
        month_key = f"{date.year}_{str(date.month).zfill(2)}"
        month_folder = os.path.join(trip_folder, month_key)
        os.makedirs(month_folder, exist_ok=True)

        month_start = date
        # Collect trips for this month per vehicle
        vehicle_month_trips = {v["id"]: [] for v in active}

        while date <= END_DATE and date.month == month_start.month:
            is_weekend = date.weekday() >= 5
            for v in active:
                # Motorcycles don't run on Sunday, box trucks limited weekends
                if v["_vtype"] == "motorcycle" and date.weekday() == 6:
                    continue
                if v["_vtype"] == "box_truck" and is_weekend:
                    if random.random() < 0.7:
                        continue

                # Trips per day per vehicle
                if v["_vtype"] == "motorcycle":
                    n_trips = random.randint(6, 18)
                elif v["_vtype"] == "cargo_van":
                    n_trips = random.randint(1, 4) if is_weekend else random.randint(2, 6)
                else:
                    n_trips = 1

                did = vehicle_driver_map[v["id"]]
                for t in range(n_trips):
                    trip = make_trip(date, v, did, t+1)
                    vehicle_month_trips[v["id"]].append(trip)
                    total_trips += 1
                    if trip["driverId"] is None:
                        no_driver_ct += 1
                    if trip["safetyEvents"]:
                        speeding_ct += 1

            date += timedelta(days=1)

        # Write one file per vehicle containing all its trips for the month
        for v in active:
            trips = vehicle_month_trips[v["id"]]
            if not trips:
                continue
            payload = {
                "vehicleId": v["id"],
                "vehicleName": v["name"],
                "month": month_key,
                "pagination": {
                    "endCursor":   trips[-1]["id"] if trips else None,
                    "hasNextPage": False,
                },
                "trips": trips,
            }
            fname = f"trips_{v['id']}.json"
            with open(os.path.join(month_folder, fname), "w") as fh:
                json.dump(payload, fh, indent=2, ensure_ascii=False)

        print(f"  {month_key}: trips written for {len(active)} vehicles")

    # ── Write driver safety summary ────────────────────────────────────────────
    summary = build_driver_summary(vehicles)
    hos_violations = [d for d in summary if d["hosViolations"]]

    summ_folder = os.path.join(OUTPUT_BASE, "driver_summary")
    os.makedirs(summ_folder, exist_ok=True)
    with open(os.path.join(summ_folder, "driver_summary.json"), "w") as fh:
        json.dump({
            "data":       summary,
            "pagination": {"endCursor": None, "hasNextPage": False},
        }, fh, indent=2, ensure_ascii=False)

    # ── Summary ────────────────────────────────────────────────────────────────
    print()
    print("=" * 45)
    print(f"Total trips        : {total_trips:,}")
    print(f"No-driver trips    : {no_driver_ct:,}  ← QUIRK 4")
    print(f"Speeding events    : {speeding_ct:,}")
    print(f"HOS violations     : {len(hos_violations)} drivers  ← QUIRK 6")
    print(f"Driver summaries   : {len(summary)}")
    print(f"Output             : {OUTPUT_BASE}")
    print()
    print("Quirks to find when you open these files:")
    print("  1. Coordinates: {latitude, longitude} named — NOT [lng,lat] like Onfleet")
    print("  2. Samsara vehicleId ≠ any Onfleet field — mapping table needed")
    print("  3. idlingDurationMs inflates trip duration")
    print("  4. Some trips have driverId: null")
    print("  5. Fuel in gallons AND in ml — pick one and convert consistently")
    print("  6. HOS violations on box truck drivers — regulatory risk")
    print("  7. Pagination uses endCursor/hasNextPage (GraphQL style)")


if __name__ == "__main__":
    main()
