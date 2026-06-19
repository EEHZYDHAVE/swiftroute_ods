"""
generators/generate_onfleet.py

Generates synthetic Onfleet API responses for SwiftRoute Logistics.
Mirrors the exact JSON structure returned by the real Onfleet Tasks API,
including all documented quirks:
  - location is [longitude, latitude] — NOT [lat, lng]
  - failureReason is "" on success, not null
  - worker is null on unassigned tasks
  - batch completion timestamps on ~4% of tasks
  - metadata fields missing on manual-entry orders

Output: data/raw/onfleet/{YYYY_MM}/page_{NNNN}.json
Each page = real Onfleet paginated response structure (max 64 tasks).

Period: 2025-01-01 to 2025-06-30
"""

import json
import os
import random
import string
from datetime import datetime, timedelta, timezone
from faker import Faker

# ── Reproducibility ────────────────────────────────────────────────────────────
SEED = 42
random.seed(SEED)
fake = Faker()
Faker.seed(SEED)

# ── Paths ──────────────────────────────────────────────────────────────────────
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT_BASE  = os.path.join(PROJECT_ROOT, "data", "raw", "onfleet")

# ── SwiftRoute org constant ────────────────────────────────────────────────────
ORG_ID = "yAM*fDkztrT3gUcz9mNDgNOL"

# ── Simulation period ──────────────────────────────────────────────────────────
START_DATE = datetime(2025, 1,  1, tzinfo=timezone.utc)
END_DATE   = datetime(2025, 6, 30, tzinfo=timezone.utc)

# ── Page size (matches real Onfleet API) ───────────────────────────────────────
PAGE_SIZE = 64

# ══════════════════════════════════════════════════════════════════════════════
#  REFERENCE DATA
# ══════════════════════════════════════════════════════════════════════════════

# ── Zones ─────────────────────────────────────────────────────────────────────
ZONES = [
    # Denver (9 zones)
    {"id":"zone_den_1","name":"Zone 1 - Downtown Denver",          "city":"denver",        "postcodes":["80202","80203"],        "fail_mod":0.80, "center":(-104.9903, 39.7392)},
    {"id":"zone_den_2","name":"Zone 2 - Capitol Hill / Cherry Creek","city":"denver",       "postcodes":["80206","80209"],        "fail_mod":0.70, "center":(-104.9597, 39.7289)},
    {"id":"zone_den_3","name":"Zone 3 - Highlands / Sloan Lake",   "city":"denver",        "postcodes":["80211","80212"],        "fail_mod":0.90, "center":(-105.0225, 39.7495)},
    {"id":"zone_den_4","name":"Zone 4 - Aurora / Stapleton",       "city":"denver",        "postcodes":["80010","80011","80238"],"fail_mod":1.10, "center":(-104.8319, 39.7294)},
    {"id":"zone_den_5","name":"Zone 5 - Englewood / Littleton",    "city":"denver",        "postcodes":["80110","80120"],        "fail_mod":0.90, "center":(-104.9878, 39.6483)},
    {"id":"zone_den_6","name":"Zone 6 - Lakewood",                 "city":"denver",        "postcodes":["80214","80215","80226"],"fail_mod":1.00, "center":(-105.0813, 39.7047)},
    {"id":"zone_den_7","name":"Zone 7 - Thornton / Northglenn",    "city":"denver",        "postcodes":["80229","80233"],        "fail_mod":1.10, "center":(-104.9719, 39.8680)},
    {"id":"zone_den_8","name":"Zone 8 - Westminster / Arvada",     "city":"denver",        "postcodes":["80003","80005"],        "fail_mod":1.00, "center":(-105.0372, 39.8366)},
    {"id":"zone_den_9","name":"Zone 9 - Parker / Castle Rock (Extended)","city":"denver",  "postcodes":["80134","80104"],        "fail_mod":1.80, "center":(-104.7618, 39.5186)},
    # Salt Lake City (4 zones)
    {"id":"zone_slc_1","name":"Zone 1 - Downtown SLC",             "city":"salt_lake_city","postcodes":["84101","84102"],        "fail_mod":0.90, "center":(-111.8910, 40.7608)},
    {"id":"zone_slc_2","name":"Zone 2 - South Salt Lake",          "city":"salt_lake_city","postcodes":["84115","84106"],        "fail_mod":1.00, "center":(-111.8883, 40.7194)},
    {"id":"zone_slc_3","name":"Zone 3 - Murray / Midvale",         "city":"salt_lake_city","postcodes":["84107","84047"],        "fail_mod":1.00, "center":(-111.8880, 40.6668)},
    {"id":"zone_slc_4","name":"Zone 4 - West Valley City",         "city":"salt_lake_city","postcodes":["84119","84120"],        "fail_mod":1.20, "center":(-112.0011, 40.6916)},
    # Albuquerque (4 zones)
    {"id":"zone_abq_1","name":"Zone 1 - Downtown Albuquerque",     "city":"albuquerque",   "postcodes":["87102","87103"],        "fail_mod":1.00, "center":(-106.6504, 35.0844)},
    {"id":"zone_abq_2","name":"Zone 2 - North Albuquerque",        "city":"albuquerque",   "postcodes":["87109","87110"],        "fail_mod":0.90, "center":(-106.6229, 35.1328)},
    {"id":"zone_abq_3","name":"Zone 3 - East Mountains",           "city":"albuquerque",   "postcodes":["87059","87068"],        "fail_mod":1.90, "center":(-106.4177, 35.0676)},
    {"id":"zone_abq_4","name":"Zone 4 - Rio Rancho",               "city":"albuquerque",   "postcodes":["87124","87144"],        "fail_mod":1.30, "center":(-106.6900, 35.2328)},
]

ZONES_BY_CITY = {}
for _z in ZONES:
    ZONES_BY_CITY.setdefault(_z["city"], []).append(_z)

# Volume share per zone within its city
ZONE_VOLUME_WEIGHT = {
    "zone_den_1":0.18,"zone_den_2":0.14,"zone_den_3":0.12,
    "zone_den_4":0.12,"zone_den_5":0.10,"zone_den_6":0.10,
    "zone_den_7":0.10,"zone_den_8":0.10,"zone_den_9":0.04,
    "zone_slc_1":0.30,"zone_slc_2":0.30,"zone_slc_3":0.25,"zone_slc_4":0.15,
    "zone_abq_1":0.35,"zone_abq_2":0.30,"zone_abq_3":0.10,"zone_abq_4":0.25,
}

# ── Service types ──────────────────────────────────────────────────────────────
SERVICE_TYPES   = ["same_day","next_day","scheduled","distribution_run"]
SERVICE_WEIGHTS = [0.35,      0.52,      0.08,       0.05]
SLA_HOURS       = {"same_day":4,"next_day":24,"scheduled":2,"distribution_run":8}

# ── Failure reasons (of the ~6% that fail) ────────────────────────────────────
FAILURE_REASONS        = ["CUST_NOT_AVAILABLE","ADDRESS_ISSUE","ACCESS_DENIED","PACKAGE_REFUSED",""]
FAILURE_REASON_WEIGHTS = [0.40,               0.30,           0.15,           0.10,             0.05]

# ── Daily base volume by city ──────────────────────────────────────────────────
BASE_VOLUME = {"denver":274, "salt_lake_city":68, "albuquerque":38}

# ── Day-of-week multiplier ─────────────────────────────────────────────────────
DOW_MULT = {0:1.00, 1:1.05, 2:1.05, 3:1.00, 4:0.95, 5:0.70, 6:0.30}

# ── City lookup helpers ────────────────────────────────────────────────────────
CITY_STATE   = {"denver":"Colorado","salt_lake_city":"Utah","albuquerque":"New Mexico"}
CITY_DISPLAY = {"denver":"Denver","salt_lake_city":"Salt Lake City","albuquerque":"Albuquerque"}

# ══════════════════════════════════════════════════════════════════════════════
#  HELPER FUNCTIONS
# ══════════════════════════════════════════════════════════════════════════════

_ID_CHARS = string.ascii_letters + string.digits + "~*"

def onfleet_id(n=24):
    """Generate an Onfleet-style random ID."""
    return "".join(random.choices(_ID_CHARS, k=n))

def short_id():
    return "".join(random.choices(string.hexdigits[:16], k=8))

def ms(dt):
    """Datetime → millisecond Unix timestamp (Onfleet's format)."""
    return int(dt.timestamp() * 1000)

def seasonal_mult(date):
    m = date.month
    if m == 1: return 0.85
    if m == 2: return 0.88
    if m in (3,4): return 1.00
    if m == 5:
        # Mother's Day 2025 = May 11; boost the surrounding week
        md = datetime(2025, 5, 11, tzinfo=timezone.utc)
        if md - timedelta(days=6) <= date <= md + timedelta(days=1):
            return 1.20
        return 1.05
    if m == 6: return 0.95
    return 1.00

# ══════════════════════════════════════════════════════════════════════════════
#  REFERENCE DATA BUILDERS
# ══════════════════════════════════════════════════════════════════════════════

def build_drivers():
    """
    Build the 48-driver roster matching the SwiftRoute operating document:
      Denver:        22 FTE + 10 IC = 32
      Salt Lake City: 7 FTE +  4 IC = 11
      Albuquerque:    3 FTE +  2 IC =  5
    Each driver has a failure_rate_modifier so some are clearly better than others.
    Two Denver FTE drivers are the known underperformers (modifier ~2.0).
    """
    random.seed(100)
    Faker.seed(100)
    drivers = []

    # Vehicle pools per city
    den_vehicles = (["van"]*14 + ["motorcycle"]*6 + ["box_truck"]*2)
    random.shuffle(den_vehicles)
    slc_vehicles = (["van"]*5 + ["motorcycle"]*3 + ["box_truck"]*1)*2
    random.shuffle(slc_vehicles)

    specs = [
        # (city,        type,  count, vehicles,     fail_mods)
        ("denver",        "FTE", 22, den_vehicles,
            [0.40,0.50,0.55,0.60,0.65,0.70,0.75,0.80,0.85,0.90,
             0.90,0.95,1.00,1.00,1.00,1.05,1.10,1.15,1.20,1.30,
             1.95,2.10]),                         # ← last two are the underperformers
        ("denver",        "IC",  10, ["van"]*6+["motorcycle"]*4,
            [0.80,0.85,0.90,0.90,1.00,1.00,1.05,1.10,1.20,1.30]),
        ("salt_lake_city","FTE",  7, slc_vehicles,
            [0.60,0.75,0.90,1.00,1.00,1.10,1.25]),
        ("salt_lake_city","IC",   4, ["van","van","motorcycle","van"],
            [0.90,1.00,1.10,1.20]),
        ("albuquerque",   "FTE",  3, ["van","van","van"],
            [0.80,1.00,1.25]),
        ("albuquerque",   "IC",   2, ["van","van"],
            [1.00,1.20]),
    ]

    for city, emp_type, count, veh_pool, fail_mods in specs:
        for i in range(count):
            drivers.append({
                "id":           onfleet_id(),
                "name":         fake.name(),
                "city":         city,
                "type":         emp_type,
                "vehicle":      veh_pool[i % len(veh_pool)],
                "fail_mod":     fail_mods[i],
            })

    random.seed(SEED)
    Faker.seed(SEED)
    return drivers


def build_clients():
    """
    94 accounts: 9 Platinum, 28 Gold, 57 Standard.
    11 are fulfillment clients (no pickup task — orders come from warehouse).
    Order channel determines metadata completeness: api/portal = complete,
    whatsapp/phone = ~18-22% missing fields.
    """
    random.seed(200)
    Faker.seed(200)
    clients = []

    tiers = [
        # (tier,      count, fulfillment_count, channels)
        ("platinum",  9,     3, ["api"]),
        ("gold",      28,    5, ["api","portal","portal"]),
        ("standard",  57,    3, ["portal","portal","whatsapp","phone"]),
    ]

    cid = 1
    for tier, count, ff_count, channels in tiers:
        for i in range(count):
            is_ff = i < ff_count
            city = random.choices(
                ["denver","salt_lake_city","albuquerque"],
                weights=[0.72, 0.18, 0.10]
            )[0]
            clients.append({
                "id":             f"client_{str(cid).zfill(3)}",
                "name":           fake.company(),
                "tier":           tier,
                "city":           city,
                "is_fulfillment": is_ff,
                "service_types":  ["next_day"] if is_ff else
                                  random.choice([["same_day","next_day"],["next_day"],["next_day","scheduled"]]),
                "channel":        random.choice(channels),
            })
            cid += 1

    random.seed(SEED)
    Faker.seed(SEED)
    return clients

# ══════════════════════════════════════════════════════════════════════════════
#  TASK GENERATOR
# ══════════════════════════════════════════════════════════════════════════════

def make_task(date, city, zone, driver, client, service_type,
              is_pickup=False, linked_id=None, batch_ts_ms=None):
    """
    Build one Onfleet task JSON object.

    Quirks intentionally reproduced:
      1. location = [lng, lat]  ← longitude FIRST (GeoJSON order)
      2. failureReason = ""     ← empty string on success, not null
      3. worker = null          ← on unassigned (state 0) tasks
      4. batch_ts_ms            ← same completion timestamp across sibling tasks
      5. metadata may be sparse ← whatsapp/phone orders miss client_id / order_value
    """
    task_id  = onfleet_id()
    s_id     = short_id()

    # Task creation time: random moment in the business day
    created = date.replace(
        hour=random.randint(7, 19),
        minute=random.randint(0, 59),
        second=random.randint(0, 59),
        microsecond=0,
    )

    sla_h         = SLA_HOURS[service_type]
    complete_before = created + timedelta(hours=sla_h + random.uniform(0.5, 2.0))

    # ── Outcome ───────────────────────────────────────────────────────────────
    days_remaining = (END_DATE - date).days
    is_very_recent = days_remaining <= 3

    if is_very_recent and random.random() < 0.15:
        # A small slice of very-recent tasks are still in-flight
        state  = random.choice([0, 1, 2])   # unassigned / assigned / active
        result = None
    else:
        state = 3   # completed

    failure_rate = min(0.06 * zone["fail_mod"] * driver["fail_mod"], 0.28)

    result        = None
    fail_reason   = None
    photo_id      = None
    complete_time = None
    distance_m    = None

    if state == 3:
        if random.random() < failure_rate:
            result      = "failure"
            fail_reason = random.choices(FAILURE_REASONS, weights=FAILURE_REASON_WEIGHTS)[0]
            # QUIRK 2 note: even on failure, reason can be "" (5% of failures)
        else:
            result    = "success"
            fail_reason = ""          # QUIRK 2: empty string, NOT null
            photo_id  = f"ph_{onfleet_id(10)}"

        if batch_ts_ms:
            complete_time = batch_ts_ms    # QUIRK 4: identical timestamp
        else:
            dur = timedelta(minutes=random.randint(15, int(sla_h * 60 * 0.9)))
            complete_time = ms(created + dur)

        distance_m = round(random.uniform(180, 9000), 1)

    # ── Worker / container ────────────────────────────────────────────────────
    # QUIRK 3: unassigned tasks have null worker
    worker_id = driver["id"] if state != 0 else None

    container = {"type": "WORKER" if worker_id else "ORGANIZATION"}
    if worker_id:
        container["worker"] = worker_id
    else:
        container["organization"] = ORG_ID

    # ── Recipient ─────────────────────────────────────────────────────────────
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

    # ── Destination ───────────────────────────────────────────────────────────
    lng_c, lat_c = zone["center"]
    lng = round(lng_c + random.uniform(-0.055, 0.055), 6)
    lat = round(lat_c + random.uniform(-0.055, 0.055), 6)

    destination = {
        "id":               onfleet_id(12),
        "timeCreated":      ms(created),
        "timeLastModified": ms(created),
        # QUIRK 1: [longitude, latitude] — many people read this backwards
        "location":         [lng, lat],
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

    # ── Metadata ──────────────────────────────────────────────────────────────
    # QUIRK 5: whatsapp/phone orders have incomplete metadata
    manual = client["channel"] in ("whatsapp", "phone")
    metadata = []

    metadata.append({"name":"service_type","type":"string",
                     "value":service_type,"visibility":["api"]})

    if not manual or random.random() > 0.18:          # ~18% of manual miss client_id
        metadata.append({"name":"client_id","type":"string",
                         "value":client["id"],"visibility":["api"]})

    if not manual or random.random() > 0.22:          # ~22% of manual miss order_value
        rate = {
            "same_day":         random.uniform(8.50, 32.00),
            "next_day":         random.uniform(6.50, 24.00),
            "scheduled":        random.uniform(12.00, 28.00),
            "distribution_run": random.uniform(18.00, 60.00),
        }[service_type]
        metadata.append({"name":"order_value","type":"number",
                         "value":round(rate, 2),"visibility":["api"]})

    metadata.append({"name":"zone_id","type":"string",
                     "value":zone["id"],"visibility":["api"]})
    metadata.append({"name":"vehicle_type","type":"string",
                     "value":driver["vehicle"],"visibility":["api"]})

    # ── Completion details ────────────────────────────────────────────────────
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
        "worker":           worker_id,
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

# ══════════════════════════════════════════════════════════════════════════════
#  DAILY BATCH GENERATOR
# ══════════════════════════════════════════════════════════════════════════════

def generate_day(date, drivers, clients):
    """Return all Onfleet tasks (delivery + pickup) for one calendar day."""
    tasks = []

    for city, base_vol in BASE_VOLUME.items():
        volume = max(1, int(base_vol * seasonal_mult(date) * DOW_MULT[date.weekday()]))

        city_zones   = ZONES_BY_CITY[city]
        city_drivers = [d for d in drivers if d["city"] == city]
        city_clients = [c for c in clients if c["city"] == city] or clients
        zone_weights = [ZONE_VOLUME_WEIGHT[z["id"]] for z in city_zones]

        # One driver per day gets "batch timestamp" quirk on 2-5 consecutive tasks
        batch_driver   = random.choice(city_drivers)
        batch_ts_ms    = ms(date.replace(hour=random.randint(14,17),
                                         minute=random.randint(0,59),
                                         second=0, microsecond=0))
        batch_budget   = random.randint(2, 5)
        batch_used     = 0

        for _ in range(volume):
            zone    = random.choices(city_zones, weights=zone_weights)[0]
            driver  = random.choice(city_drivers)
            client  = random.choice(city_clients)
            svc     = random.choices(SERVICE_TYPES, weights=SERVICE_WEIGHTS)[0]

            # Enforce: fulfillment clients don't use same_day and don't generate pickup tasks
            if client["is_fulfillment"] and svc == "same_day":
                svc = "next_day"

            # Batch-timestamp quirk for the chosen driver
            use_batch = (
                driver["id"] == batch_driver["id"]
                and batch_used < batch_budget
                and random.random() < 0.65
            )
            b_ts = batch_ts_ms if use_batch else None
            if use_batch:
                batch_used += 1

            # Delivery task
            delivery = make_task(date, city, zone, driver, client, svc,
                                 is_pickup=False, batch_ts_ms=b_ts)
            tasks.append(delivery)

            # Pickup task: ~60% of non-fulfillment orders
            if not client["is_fulfillment"] and random.random() < 0.60:
                pickup = make_task(date, city, zone, driver, client, svc,
                                   is_pickup=True,
                                   linked_id=delivery["id"],
                                   batch_ts_ms=b_ts)
                # Pickup created slightly earlier than the delivery task
                offset = random.randint(5, 90) * 60 * 1000   # 5-90 minutes in ms
                pickup["timeCreated"] -= offset
                tasks.append(pickup)

    return tasks

# ══════════════════════════════════════════════════════════════════════════════
#  PAGINATION & FILE WRITER
# ══════════════════════════════════════════════════════════════════════════════

def write_month(month_tasks, year, month):
    """Split month_tasks into 64-task pages and write to disk."""
    folder = os.path.join(OUTPUT_BASE, f"{year}_{str(month).zfill(2)}")
    os.makedirs(folder, exist_ok=True)

    pages = [month_tasks[i:i+PAGE_SIZE] for i in range(0, len(month_tasks), PAGE_SIZE)]
    total_pages = len(pages)

    for idx, page in enumerate(pages, start=1):
        is_last = idx == total_pages
        payload = {
            # lastId = cursor for next page; null on final page
            "lastId": None if is_last else page[-1]["id"],
            "tasks":  page,
        }
        path = os.path.join(folder, f"page_{str(idx).zfill(4)}.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2, ensure_ascii=False)

    return len(pages)

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════

def main():
    print("SwiftRoute — Onfleet raw data generator")
    print("=" * 45)

    drivers = build_drivers()
    clients = build_clients()

    print(f"Drivers : {len(drivers)}  "
          f"({sum(1 for d in drivers if d['type']=='FTE')} FTE, "
          f"{sum(1 for d in drivers if d['type']=='IC')} IC)")
    print(f"Clients : {len(clients)}  "
          f"({sum(1 for c in clients if c['is_fulfillment'])} fulfillment)")
    print(f"Zones   : {len(ZONES)}")
    print(f"Period  : {START_DATE.date()} → {END_DATE.date()}")
    print()

    month_tasks   = []
    current_month = START_DATE.month
    current_year  = START_DATE.year
    total_tasks   = 0
    total_pages   = 0

    date = START_DATE
    while date <= END_DATE:
        day_tasks = generate_day(date, drivers, clients)

        # When the month rolls over, flush the previous month to disk
        if date.month != current_month:
            p = write_month(month_tasks, current_year, current_month)
            total_tasks += len(month_tasks)
            total_pages += p
            print(f"  2025-{str(current_month).zfill(2)}: "
                  f"{len(month_tasks):>6,} tasks  →  {p:>4} pages")
            month_tasks   = []
            current_month = date.month
            current_year  = date.year

        month_tasks.extend(day_tasks)
        date += timedelta(days=1)

    # Flush final month
    if month_tasks:
        p = write_month(month_tasks, current_year, current_month)
        total_tasks += len(month_tasks)
        total_pages += p
        print(f"  2025-{str(current_month).zfill(2)}: "
              f"{len(month_tasks):>6,} tasks  →  {p:>4} pages")

    # Quick sanity stats
    print()
    print("=" * 45)
    print(f"Total tasks  : {total_tasks:,}")
    print(f"Total pages  : {total_pages:,}")
    print(f"Output folder: {OUTPUT_BASE}")
    print()
    print("Spot-check a random page to verify structure:")
    print("  python -c \"import json,os; "
          "p=json.load(open(os.path.join(r'" + OUTPUT_BASE.replace("\\","\\\\") + r"','2025_01','page_0001.json'))); "
          "print('Tasks on page:', len(p['tasks'])); "
          "print('lastId present:', p['lastId'] is not None); "
          "t=p['tasks'][0]; "
          "print('Sample task state:', t['state']); "
          "print('location format:', t['destination']['location'])\"")

if __name__ == "__main__":
    main()
