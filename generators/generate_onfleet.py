"""
generators/generate_onfleet.py

Generates synthetic Onfleet API responses for SwiftRoute Logistics.
Imports DRIVERS, CLIENTS, ZONES from shared_ids.py (written by
generate_shared_ids.py, which must run first) — shared_ids.py is
authoritative for driver/client/zone identity. This generator only adds
Onfleet-specific fields (metadata, task structure, worker records) on
top of that canonical data.

Two outputs now, mirroring the real Onfleet API's split between Tasks
and Workers:
  1. Task/delivery data — source_data/raw/onfleet/{YYYY_MM}/page_{NNNN}.json
     Real API structure, worker field is an ID ONLY (no embedded name —
     that's how the real Onfleet Tasks endpoint actually works).
  2. Worker roster — source_data/raw/onfleet/workers/workers.json
     Real API structure for GET /workers — this is the only place a
     name is resolvable for a given worker ID, same as the real platform.

Quirks intentionally reproduced:
  1. location is [longitude, latitude] — NOT [lat, lng]
  2. failureReason is "" on success, not null
  3. worker is null on unassigned tasks
  4. batch completion timestamps on ~4% of tasks
  5. metadata fields missing on manual-entry (whatsapp/phone) orders
  6. a terminated driver stops receiving new task assignments after
     their termination_date (drops out of the eligible pool for that
     day, same mechanism used in generate_samsara.py)

Period: 2025-01-01 to 2025-06-30
"""

import json
import os
import random
import string
from datetime import datetime, timedelta, timezone
from faker import Faker

import shared_ids

SEED = 42
random.seed(SEED)
fake = Faker()
Faker.seed(SEED)

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT_BASE  = os.path.join(PROJECT_ROOT, "source_data", "raw", "onfleet")

ORG_ID = "yAM*fDkztrT3gUcz9mNDgNOL"

START_DATE = datetime(2025, 1,  1, tzinfo=timezone.utc)
END_DATE   = datetime(2025, 6, 30, tzinfo=timezone.utc)
PAGE_SIZE  = 64

# ── Zone volume weighting — Onfleet-generation-specific, not a shared
#    business fact, so it stays local. Keyed by shared_ids zone_id. ──────────
ZONE_VOLUME_WEIGHT = {
    "zone_den_1":0.18,"zone_den_2":0.14,"zone_den_3":0.12,
    "zone_den_4":0.12,"zone_den_5":0.10,"zone_den_6":0.10,
    "zone_den_7":0.10,"zone_den_8":0.10,"zone_den_9":0.04,
    "zone_slc_1":0.30,"zone_slc_2":0.30,"zone_slc_3":0.25,"zone_slc_4":0.15,
    "zone_abq_1":0.35,"zone_abq_2":0.30,"zone_abq_3":0.10,"zone_abq_4":0.25,
}

SERVICE_TYPES   = ["same_day","next_day","scheduled","distribution_run"]
SERVICE_WEIGHTS = [0.35,      0.52,      0.08,       0.05]
SLA_HOURS       = {"same_day":4,"next_day":24,"scheduled":2,"distribution_run":8}

FAILURE_REASONS        = ["CUST_NOT_AVAILABLE","ADDRESS_ISSUE","ACCESS_DENIED","PACKAGE_REFUSED",""]
FAILURE_REASON_WEIGHTS = [0.40,               0.30,           0.15,           0.10,             0.05]

BASE_VOLUME = {"denver":274, "salt_lake_city":68, "albuquerque":38}
DOW_MULT = {0:1.00, 1:1.05, 2:1.05, 3:1.00, 4:0.95, 5:0.70, 6:0.30}

CITY_STATE   = {"denver":"Colorado","salt_lake_city":"Utah","albuquerque":"New Mexico"}
CITY_DISPLAY = {"denver":"Denver","salt_lake_city":"Salt Lake City","albuquerque":"Albuquerque"}

_ID_CHARS = string.ascii_letters + string.digits + "~*"


def onfleet_id(n=24):
    return "".join(random.choices(_ID_CHARS, k=n))

def short_id():
    return "".join(random.choices(string.hexdigits[:16], k=8))

def ms(dt):
    return int(dt.timestamp() * 1000)

def seasonal_mult(date):
    m = date.month
    if m == 1: return 0.85
    if m == 2: return 0.88
    if m in (3,4): return 1.00
    if m == 5:
        md = datetime(2025, 5, 11, tzinfo=timezone.utc)
        if md - timedelta(days=6) <= date <= md + timedelta(days=1):
            return 1.20
        return 1.05
    if m == 6: return 0.95
    return 1.00

def is_driver_active_on(driver, date_obj):
    if driver["_termination_date"] is None:
        return True
    term = datetime.strptime(driver["_termination_date"], "%Y-%m-%d").date()
    return date_obj <= term


# ══════════════════════════════════════════════════════════════════════════
#  REFERENCE DATA — adapted from shared_ids, not invented
# ══════════════════════════════════════════════════════════════════════════

def build_zones():
    """Adapt shared_ids.ZONES into the shape this generator's task builder
    expects, keeping zone_id so ZONE_VOLUME_WEIGHT lookups still work."""
    zones = []
    for z in shared_ids.ZONES:
        zones.append({
            "id":        z["zone_id"],
            "name":      z["zone_name"],
            "city":      z["city"],
            "postcodes": z["postcodes"],
            "fail_mod":  z["fail_mod"],
            "center":    (z["center_lng"], z["center_lat"]),
        })
    return zones


def build_drivers():
    """Adapt shared_ids.DRIVERS into the shape the task builder expects.
    Identity (id, name, fail_mod) comes straight from shared_ids — no
    fabrication. IC and FTE drivers are both eligible for Onfleet tasks
    (unlike Samsara, which is FTE-only — Onfleet dispatches everyone who
    delivers, regardless of employment type)."""
    drivers = []
    for d in shared_ids.DRIVERS:
        drivers.append({
            "id":                d["onfleet_worker_id"],
            "name":              d["full_name"],
            "city":              d["city"],
            "type":              d["employment_type"],
            "vehicle":           "van" if d["vehicle_type"] == "cargo_van" else d["vehicle_type"],
            "fail_mod":          d["fail_mod"],
            "_termination_date": d["termination_date"],
        })
    return drivers


def build_clients():
    """Adapt shared_ids.CLIENTS into the shape the task builder expects."""
    clients = []
    for c in shared_ids.CLIENTS:
        clients.append({
            "id":             c["internal_id"],
            "name":           c["name"],
            "tier":           c["tier"],
            "city":           c["city"],
            "is_fulfillment": c["is_fulfillment"],
            "service_types":  c["service_types"],
            "channel":        c["channel"],
        })
    return clients


# ══════════════════════════════════════════════════════════════════════════
#  WORKERS ENDPOINT — new: mirrors real GET /workers
# ══════════════════════════════════════════════════════════════════════════

def build_workers():
    """
    Mirrors Onfleet's real Workers endpoint. This is the ONLY place a
    driver's name is resolvable — task objects only ever carry the
    worker ID, exactly like the real platform. A terminated driver still
    appears here (Onfleet doesn't delete history) but is flagged off-duty.
    """
    random.seed(150)
    workers = []
    for d in shared_ids.DRIVERS:
        is_terminated = d["termination_date"] is not None
        workers.append({
            "id":                d["onfleet_worker_id"],
            "organization":      ORG_ID,
            "name":              d["full_name"],
            "phone":             fake.numerify("+1##########"),
            "displayName":       d["full_name"].split(" ")[0],
            "teams":             [f"team_{d['city']}"],
            "vehicle": {
                "id":          onfleet_id(12),
                "type":        "CAR" if d["vehicle_type"] == "cargo_van" else d["vehicle_type"].upper(),
                "description": d["vehicle_type"].replace("_", " ").title(),
                "licensePlate": f"{random.choice(string.ascii_uppercase)}{random.choice(string.ascii_uppercase)}{random.randint(1000,9999)}",
                "color":       random.choice(["white", "silver", "blue", "black"]),
            },
            "imageUrl":          None,
            "timeCreated":       ms(datetime(2024, 1, 1, tzinfo=timezone.utc)),
            "timeLastModified":  ms(datetime(2025, int(d["termination_date"][5:7]), int(d["termination_date"][8:10]), tzinfo=timezone.utc)) if is_terminated else ms(END_DATE),
            "onDuty":            not is_terminated,
            "activeTask":        None,
            "metadata": [
                {"name": "employment_type", "type": "string", "value": d["employment_type"], "visibility": ["api"]},
            ],
            "_ods_note": (
                "This is the only Onfleet file where a driver name is "
                "resolvable. Task objects only carry the worker ID."
            ),
        })
    random.seed(SEED)
    return workers


# ══════════════════════════════════════════════════════════════════════════
#  TASK GENERATOR (unchanged logic — identity now sourced, not invented)
# ══════════════════════════════════════════════════════════════════════════

def make_task(date, city, zone, driver, client, service_type,
              is_pickup=False, linked_id=None, batch_ts_ms=None):
    task_id  = onfleet_id()
    s_id     = short_id()

    created = date.replace(
        hour=random.randint(7, 19),
        minute=random.randint(0, 59),
        second=random.randint(0, 59),
        microsecond=0,
    )

    sla_h = SLA_HOURS[service_type]
    complete_before = created + timedelta(hours=sla_h + random.uniform(0.5, 2.0))

    days_remaining = (END_DATE - date).days
    is_very_recent = days_remaining <= 3

    if is_very_recent and random.random() < 0.15:
        state  = random.choice([0, 1, 2])
        result = None
    else:
        state = 3

    failure_rate = min(0.06 * zone["fail_mod"] * driver["fail_mod"], 0.28)

    result = None
    fail_reason = None
    photo_id = None
    complete_time = None
    distance_m = None

    if state == 3:
        if random.random() < failure_rate:
            result = "failure"
            fail_reason = random.choices(FAILURE_REASONS, weights=FAILURE_REASON_WEIGHTS)[0]
        else:
            result = "success"
            fail_reason = ""
            photo_id = f"ph_{onfleet_id(10)}"

        if batch_ts_ms:
            complete_time = batch_ts_ms
        else:
            dur = timedelta(minutes=random.randint(15, int(sla_h * 60 * 0.9)))
            complete_time = ms(created + dur)

        distance_m = round(random.uniform(180, 9000), 1)

    worker_id = driver["id"] if state != 0 else None
    container = {"type": "WORKER" if worker_id else "ORGANIZATION"}
    if worker_id:
        container["worker"] = worker_id
    else:
        container["organization"] = ORG_ID

    recipient = {
        "id":                   onfleet_id(14),
        "organization":         ORG_ID,
        "timeCreated":          ms(created - timedelta(days=random.randint(0, 60))),
        "timeLastModified":     ms(created),
        "name":                 fake.name(),
        "phone":                f"+1{random.randint(2002000000, 9999999999)}",
        "notes":                random.choice(["","","","Call on arrival","Leave with concierge"]),
        "skipSMSNotifications": random.random() < 0.08,
        "hashedPhone":          onfleet_id(16),
    }

    lng_c, lat_c = zone["center"]
    lng = round(lng_c + random.uniform(-0.055, 0.055), 6)
    lat = round(lat_c + random.uniform(-0.055, 0.055), 6)

    destination = {
        "id":               onfleet_id(12),
        "timeCreated":      ms(created),
        "timeLastModified": ms(created),
        "location":         [lng, lat],   # QUIRK 1: [lng, lat]
        "address": {
            "apartment":  random.choice(["","","",f"Apt {random.randint(1,400)}",f"Ste {random.randint(100,999)}"]),
            "state":      CITY_STATE[city],
            "postalCode": random.choice(zone["postcodes"]),
            "country":    "United States",
            "city":       CITY_DISPLAY[city],
            "street":     fake.street_name(),
            "number":     str(random.randint(1, 9999)),
            "name":       "",
        },
        "notes":    "",
        "metadata": [],
    }

    manual = client["channel"] in ("whatsapp", "phone")
    metadata = []
    metadata.append({"name":"service_type","type":"string","value":service_type,"visibility":["api"]})
    if not manual or random.random() > 0.18:
        metadata.append({"name":"client_id","type":"string","value":client["id"],"visibility":["api"]})
    if not manual or random.random() > 0.22:
        rate = {
            "same_day":         random.uniform(8.50, 32.00),
            "next_day":         random.uniform(6.50, 24.00),
            "scheduled":        random.uniform(12.00, 28.00),
            "distribution_run": random.uniform(18.00, 60.00),
        }[service_type]
        metadata.append({"name":"order_value","type":"number","value":round(rate, 2),"visibility":["api"]})
    metadata.append({"name":"zone_id","type":"string","value":zone["id"],"visibility":["api"]})
    metadata.append({"name":"vehicle_type","type":"string","value":driver["vehicle"],"visibility":["api"]})

    completion_details = {
        "failureReason":        fail_reason if fail_reason is not None else "",
        "successNotes":         "",
        "successEvidence":      "",
        "photoUploadId":        photo_id,
        "photoUploadIds":       [photo_id] if photo_id else [],
        "signatureUploadId":    None,
        "time":                 complete_time,
        "firstPhotoUploadId":   photo_id,
        "unavailableAttachments": [],
        "actions":              {},
        "distance":             distance_m,
        "result":               result,
    }

    last_modified_ts = complete_time if complete_time else ms(created)

    return {
        "id":               task_id,
        "timeCreated":      ms(created),
        "timeLastModified": last_modified_ts,
        "organization":     ORG_ID,
        "shortId":          s_id,
        "trackingURL":      f"https://onfleet.com/track/{s_id}",
        "worker":           worker_id,   # ID ONLY — resolve name via workers.json
        "merchant":         ORG_ID,
        "executor":         ORG_ID,
        "creator":          worker_id if worker_id else ORG_ID,
        "dependencies":     [linked_id] if linked_id else [],
        "state":            state,
        "completeAfter":    ms(created) if random.random() > 0.30 else None,
        "completeBefore":   ms(complete_before),
        "pickupTask":       is_pickup,
        "notes":            random.choice([
                                "","","",
                                "Leave at front door if no answer.",
                                f"Gate code {random.randint(1000,9999)}",
                                "Fragile — handle with care.",
                                "Call recipient 10 min before arrival.",
                            ]),
        "completionDetails": completion_details,
        "feedback":         [],
        "metadata":         metadata,
        "overrides":        {},
        "quantity":         random.choices([1,1,1,2,3],[0.70,0.10,0.10,0.05,0.05])[0],
        "serviceTime":      random.choice([2,3,3,5,5,10]),
        "identity":         {"failedScanCount":0,"checksum":None},
        "appearance":       {"triangleColor":None},
        "container":        container,
        "recipients":       [recipient],
        "destination":      destination,
        "estimatedArrivalTime":    complete_time - 5*60*1000 if complete_time else None,
        "estimatedCompletionTime": complete_time,
        "barcodes":         {"require":[],"capture":[],"captureMaxCount":None},
    }


# ══════════════════════════════════════════════════════════════════════════
#  DAILY BATCH GENERATOR
# ══════════════════════════════════════════════════════════════════════════

def generate_day(date, drivers, clients, zones):
    tasks = []
    zones_by_city = {}
    for z in zones:
        zones_by_city.setdefault(z["city"], []).append(z)

    for city, base_vol in BASE_VOLUME.items():
        volume = max(1, int(base_vol * seasonal_mult(date) * DOW_MULT[date.weekday()]))

        city_zones = zones_by_city[city]
        # QUIRK 6: only drivers still active as of this date are eligible
        city_drivers = [d for d in drivers if d["city"] == city and is_driver_active_on(d, date.date())]
        city_clients = [c for c in clients if c["city"] == city] or clients
        zone_weights = [ZONE_VOLUME_WEIGHT[z["id"]] for z in city_zones]

        if not city_drivers:
            continue

        batch_driver = random.choice(city_drivers)
        batch_ts_ms = ms(date.replace(hour=random.randint(14,17), minute=random.randint(0,59), second=0, microsecond=0))
        batch_budget = random.randint(2, 5)
        batch_used = 0

        for _ in range(volume):
            zone   = random.choices(city_zones, weights=zone_weights)[0]
            driver = random.choice(city_drivers)
            client = random.choice(city_clients)
            svc    = random.choices(SERVICE_TYPES, weights=SERVICE_WEIGHTS)[0]

            if client["is_fulfillment"] and svc == "same_day":
                svc = "next_day"

            use_batch = (
                driver["id"] == batch_driver["id"]
                and batch_used < batch_budget
                and random.random() < 0.65
            )
            b_ts = batch_ts_ms if use_batch else None
            if use_batch:
                batch_used += 1

            delivery = make_task(date, city, zone, driver, client, svc, is_pickup=False, batch_ts_ms=b_ts)
            tasks.append(delivery)

            if not client["is_fulfillment"] and random.random() < 0.60:
                pickup = make_task(date, city, zone, driver, client, svc,
                                    is_pickup=True, linked_id=delivery["id"], batch_ts_ms=b_ts)
                offset = random.randint(5, 90) * 60 * 1000
                pickup["timeCreated"] -= offset
                tasks.append(pickup)

    return tasks


# ══════════════════════════════════════════════════════════════════════════
#  PAGINATION & FILE WRITER
# ══════════════════════════════════════════════════════════════════════════

def write_month(month_tasks, year, month):
    folder = os.path.join(OUTPUT_BASE, f"{year}_{str(month).zfill(2)}")
    os.makedirs(folder, exist_ok=True)

    pages = [month_tasks[i:i+PAGE_SIZE] for i in range(0, len(month_tasks), PAGE_SIZE)]
    total_pages = len(pages)

    for idx, page in enumerate(pages, start=1):
        is_last = idx == total_pages
        payload = {
            "lastId": None if is_last else page[-1]["id"],
            "tasks":  page,
        }
        path = os.path.join(folder, f"page_{str(idx).zfill(4)}.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2, ensure_ascii=False)

    return len(pages)


# ══════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════

def main():
    print("SwiftRoute — Onfleet raw data generator")
    print("=" * 45)

    drivers = build_drivers()
    clients = build_clients()
    zones   = build_zones()

    print(f"Drivers : {len(drivers)}  "
          f"({sum(1 for d in drivers if d['type']=='FTE')} FTE, "
          f"{sum(1 for d in drivers if d['type']=='IC')} IC)")
    print(f"Clients : {len(clients)}  ({sum(1 for c in clients if c['is_fulfillment'])} fulfillment)")
    print(f"Zones   : {len(zones)}")
    print(f"Period  : {START_DATE.date()} → {END_DATE.date()}")
    print()

    # ── Workers endpoint ─────────────────────────────────────────────────────
    workers = build_workers()
    workers_folder = os.path.join(OUTPUT_BASE, "workers")
    os.makedirs(workers_folder, exist_ok=True)
    with open(os.path.join(workers_folder, "workers.json"), "w", encoding="utf-8") as fh:
        json.dump(workers, fh, indent=2, ensure_ascii=False)
    print(f"Workers written to workers/workers.json  ({len(workers)} records)")
    print()

    # ── Tasks ────────────────────────────────────────────────────────────────
    month_tasks   = []
    current_month = START_DATE.month
    current_year  = START_DATE.year
    total_tasks   = 0
    total_pages   = 0

    date = START_DATE
    while date <= END_DATE:
        day_tasks = generate_day(date, drivers, clients, zones)

        if date.month != current_month:
            p = write_month(month_tasks, current_year, current_month)
            total_tasks += len(month_tasks)
            total_pages += p
            print(f"  2025-{str(current_month).zfill(2)}: {len(month_tasks):>6,} tasks  →  {p:>4} pages")
            month_tasks   = []
            current_month = date.month
            current_year  = date.year

        month_tasks.extend(day_tasks)
        date += timedelta(days=1)

    if month_tasks:
        p = write_month(month_tasks, current_year, current_month)
        total_tasks += len(month_tasks)
        total_pages += p
        print(f"  2025-{str(current_month).zfill(2)}: {len(month_tasks):>6,} tasks  →  {p:>4} pages")

    print()
    print("=" * 45)
    print(f"Total tasks  : {total_tasks:,}")
    print(f"Total pages  : {total_pages:,}")
    print(f"Output folder: {OUTPUT_BASE}")


if __name__ == "__main__":
    main()