"""
generators/generate_shared_ids.py

Originates shared_ids.py — the canonical master data for SwiftRoute
Logistics: DRIVERS, VEHICLES, CLIENTS, ZONES.

This file has NO relationship to any of the six external systems (Gusto,
Samsara, Onfleet, Linnworks, QuickBooks, Salesforce). It represents the
business's own ground truth — who its drivers/vehicles/clients/zones are —
independent of which SaaS tools happen to track pieces of that truth.

Run this FIRST, before any of the six system generators. They all import
from generators/shared_ids.py, which this script writes.

SEED = 42
"""

import os
import random
import uuid
from datetime import datetime, timedelta
from faker import Faker

SEED = 42
random.seed(SEED)
fake = Faker()
Faker.seed(SEED)

SHARED_IDS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "shared_ids.py")

# ── City / fleet configuration ───────────────────────────────────────────────
# ASSUMPTION: vehicle_type mix per driver, within a city, is allocated
# proportionally to that city's actual vehicle inventory mix. Drivers
# outnumber vehicles (48 vs 35) so some vehicles are shared across drivers
# (shift-based reuse) — mirrors real fleets where not every driver has a
# dedicated vehicle.
CITY_CONFIG = {
    "denver": {
        "abbr": "DEN", "fte": 22, "ic": 10,
        "vehicles": {"cargo_van": 14, "motorcycle": 6, "box_truck": 2},
        "zone_count": 9, "coords": (39.7392, -104.9903),
    },
    "salt_lake_city": {
        "abbr": "SLC", "fte": 7, "ic": 4,
        "vehicles": {"cargo_van": 5, "motorcycle": 3, "box_truck": 1},
        "zone_count": 4, "coords": (40.7608, -111.8910),
    },
    "albuquerque": {
        "abbr": "ABQ", "fte": 3, "ic": 2,
        "vehicles": {"cargo_van": 3, "motorcycle": 1, "box_truck": 0},
        "zone_count": 4, "coords": (35.0844, -106.6504),
    },
}

VEHICLE_META = {
    "cargo_van":  {"label": "Cargo Van",  "make": "Ford",  "model": "Transit 250", "fuel": "gasoline", "code": "VAN"},
    "motorcycle": {"label": "Motorcycle", "make": "Honda", "model": "CB300R",      "fuel": "gasoline", "code": "MOTO"},
    "box_truck":  {"label": "Box Truck",  "make": "Isuzu", "model": "NPR-HD",      "fuel": "diesel",   "code": "BOX"},
}

DRIVER_SALARY_RANGES = {
    "denver":          (38000, 62000),
    "salt_lake_city":  (40000, 52000),
    "albuquerque":     (38000, 48000),
}
DRIVER_BONUS_MAX = {"denver": 400, "salt_lake_city": 350, "albuquerque": 300}


def repr_py(obj, indent=0):
    pad = "    " * indent
    if isinstance(obj, dict):
        lines = ["{"]
        for k, v in obj.items():
            lines.append(f"{pad}    {k!r}: {repr_py(v, indent + 1)},")
        lines.append(pad + "}")
        return "\n".join(lines)
    if isinstance(obj, list):
        lines = ["["]
        for item in obj:
            lines.append(f"{pad}    {repr_py(item, indent + 1)},")
        lines.append(pad + "]")
        return "\n".join(lines)
    return repr(obj)


# ══════════════════════════════════════════════════════════════════════════
#  BUILDERS
# ══════════════════════════════════════════════════════════════════════════

def build_zones():
    """17 zones: 9 Denver, 4 SLC, 4 ABQ. zone_den_9 and zone_abq_3 are
    remote zones with elevated fail_mod."""
    random.seed(800)
    zones = []
    for city, cfg in CITY_CONFIG.items():
        abbr = cfg["abbr"].lower()
        lat0, lng0 = cfg["coords"]
        for i in range(1, cfg["zone_count"] + 1):
            zone_id = f"zone_{abbr}_{i}"
            fail_mod = round(random.uniform(0.70, 1.10), 2)
            if zone_id == "zone_den_9":
                fail_mod = 1.80
            if zone_id == "zone_abq_3":
                fail_mod = 1.90
            zip_lo, zip_hi = {"denver": (80000, 89999), "salt_lake_city": (84000, 84999), "albuquerque": (87000, 87999)}[city]
            zones.append({
                "zone_id":    zone_id,
                "zone_name":  f"Zone {i} - {city.replace('_', ' ').title()}",
                "city":       city,
                "postcodes":  [str(random.randint(zip_lo, zip_hi)) for _ in range(random.randint(1, 3))],
                "fail_mod":   fail_mod,
                "center_lng": round(lng0 + random.uniform(-0.15, 0.15), 4),
                "center_lat": round(lat0 + random.uniform(-0.15, 0.15), 4),
                "surcharge":  1.50 if fail_mod >= 1.5 else 1.00,
            })
    random.seed(SEED)
    return zones


def build_clients():
    """94 clients: 9 platinum / 28 gold / 57 standard.
    client_001..client_011 are fulfillment clients.
    ASSUMPTION: city split weighted ~63/21/10 (Denver/SLC/ABQ), proportional
    to delivery-volume weighting — not specified explicitly in the doc."""
    random.seed(900)
    Faker.seed(900)
    TOTAL = 94
    tiers = ["platinum"] * 9 + ["gold"] * 28 + ["standard"] * 57
    random.shuffle(tiers)

    city_pool = ["denver"] * 63 + ["salt_lake_city"] * 21 + ["albuquerque"] * 10
    random.shuffle(city_pool)

    clients = []
    for i in range(1, TOTAL + 1):
        internal_id = f"client_{i:03d}"
        is_fulfillment = i <= 11
        tier = tiers[i - 1]
        company_name = fake.company()
        discount_by_tier = {"platinum": (0.15, 0.20), "gold": (0.08, 0.14), "standard": (0.0, 0.07)}
        discount = round(random.uniform(*discount_by_tier[tier]), 2)

        client = {
            "internal_id":    internal_id,
            "sf_account_id":  "001" + uuid.uuid4().hex[:15],
            "qb_customer_id": str(1000 + i),
            "name":           company_name,
            "tier":           tier,
            "city":           city_pool[i - 1],
            "is_fulfillment": is_fulfillment,
            "contract_type":  random.choice(["Fixed Rate", "Variable Rate"]),
            "payment_terms":  30,
            "discount_rate":  discount,
            "channel":        random.choice(["api", "email", "whatsapp", "phone", "portal"]),
        }

        if is_fulfillment:
            client["service_types"] = ["next_day", "fulfillment_pick", "storage"]
            client["daily_orders_lo"] = random.randint(10, 20)
            client["daily_orders_hi"] = client["daily_orders_lo"] + random.randint(8, 16)
            prefix = "".join(ch for ch in company_name.upper() if ch.isalpha())[:4] or "SKU"
            client["sku_prefix"] = prefix
            client["sku_count"] = random.randint(12, 40)
        else:
            client["service_types"] = random.sample(["next_day", "same_day", "white_glove"], k=random.randint(1, 2))
            client["daily_orders_lo"] = None
            client["daily_orders_hi"] = None
            client["sku_prefix"] = None
            client["sku_count"] = None

        clients.append(client)

    # QUIRK: exactly 2 clients on net-60 terms — everyone else is net-30
    for c in random.sample(clients, 2):
        c["payment_terms"] = 60

    random.seed(SEED)
    Faker.seed(SEED)
    return clients


def build_vehicles():
    """35 vehicles. One Denver cargo van is permanently out of service."""
    random.seed(600)
    vehicles = []
    for city, cfg in CITY_CONFIG.items():
        abbr = cfg["abbr"]
        for vtype, count in cfg["vehicles"].items():
            meta = VEHICLE_META[vtype]
            for seq in range(1, count + 1):
                is_active = not (city == "denver" and vtype == "cargo_van" and seq == count)
                vehicles.append({
                    "samsara_vehicle_id":   str(random.randint(40000000, 49999999)),
                    "onfleet_vehicle_type": "van" if vtype == "cargo_van" else vtype,
                    "vehicle_name":         f"{abbr}-{meta['code']}-{seq:02d}",
                    "vehicle_type":         vtype,
                    "label":                meta["label"],
                    "city":                 city,
                    "make":                 meta["make"],
                    "model":                meta["model"],
                    "year":                 random.randint(2019, 2023),
                    "fuel_type":            meta["fuel"],
                    "is_active":            is_active,
                    # NOTE: no fixed driver assignment. Vehicles are a pure
                    # business asset pool — any eligible driver (matching
                    # city + vehicle_type, active on the given date) can
                    # drive any matching vehicle. Assignment is decided
                    # dynamically by whichever generator needs it (Samsara,
                    # Onfleet), not fixed here.
                })
    random.seed(SEED)
    return vehicles


def build_drivers(vehicles):
    """48 drivers (32 FTE + 16 IC). IC drivers get a synthetic gusto_uuid
    for referential consistency (they have no real Gusto record; Gusto's
    own generator will simply exclude employment_type == 'IC' from its
    employee roster).

    A single Denver FTE driver is marked terminated here — a genuine
    business fact, not a Gusto-only one, so Samsara/Onfleet can also
    respect it once we build those generators.
    """
    drivers = []
    onfleet_seq = {"FTE": 1, "IC": 1}
    samsara_seq = 20000001
    elevated_fail_mods = [1.95, 2.10]
    dept_label = {"denver": "Denver", "salt_lake_city": "SLC", "albuquerque": "ABQ"}
    random.seed(1000)
    Faker.seed(1000)

    for city, cfg in CITY_CONFIG.items():
        total_drivers_city = cfg["fte"] + cfg["ic"]
        type_counts = cfg["vehicles"]
        total_vtype = sum(type_counts.values())

        type_alloc = []
        for vtype, vcount in type_counts.items():
            n = round(total_drivers_city * (vcount / total_vtype)) if total_vtype else 0
            type_alloc += [vtype] * n
        while len(type_alloc) < total_drivers_city:
            type_alloc.append(random.choice(list(type_counts.keys())))
        while len(type_alloc) > total_drivers_city:
            type_alloc.pop()
        random.shuffle(type_alloc)

        driver_slots = [("FTE", i) for i in range(cfg["fte"])] + [("IC", i) for i in range(cfg["ic"])]

        for slot_idx, (emp_type, _) in enumerate(driver_slots):
            vtype = type_alloc[slot_idx]

            first, last = fake.first_name(), fake.last_name()
            g_uuid = str(uuid.uuid4())
            onfleet_id = f"drv_{emp_type.lower()}_{onfleet_seq[emp_type]:03d}"
            onfleet_seq[emp_type] += 1
            samsara_id = str(samsara_seq)
            samsara_seq += 1

            if emp_type == "FTE":
                dept = f"Drivers — {dept_label[city]} FTE"
                annual_salary = random.randint(*DRIVER_SALARY_RANGES[city])
                bi_weekly_gross = round(annual_salary / 26, 2)
                hire_date = (datetime(2024, 1, 1) - timedelta(days=random.randint(0, 1460))).strftime("%Y-%m-%d")
            else:
                dept = f"Drivers — {dept_label[city]} IC"
                annual_salary = None
                bi_weekly_gross = None
                hire_date = None

            driver = {
                "gusto_uuid":         g_uuid,
                "onfleet_worker_id":  onfleet_id,
                "samsara_driver_id":  samsara_id,
                "full_name":          f"{first} {last}",
                "first_name":         first,
                "last_name":          last,
                "email":              fake.email(),
                "city":               city,
                "employment_type":    emp_type,
                "vehicle_type":       vtype,
                "department":         dept,
                "annual_salary":      annual_salary,
                "bi_weekly_gross":    bi_weekly_gross,
                "hire_date":          hire_date,
                "is_active":          True,
                "termination_date":   None,
                "fail_mod":           round(random.uniform(0.70, 1.10), 2),
            }
            drivers.append(driver)

    # Two known-underperformer Denver FTE drivers
    denver_fte = [d for d in drivers if d["city"] == "denver" and d["employment_type"] == "FTE"]
    for d, fm in zip(random.sample(denver_fte, 2), elevated_fail_mods):
        d["fail_mod"] = fm

    # One canonical mid-simulation termination — a Denver FTE driver,
    # excluding the two underperformers so the signals stay distinct.
    remaining = [d for d in denver_fte if d["fail_mod"] not in elevated_fail_mods]
    terminated_driver = random.choice(remaining)
    term_dt = datetime(2025, random.randint(2, 4), random.randint(1, 25))
    terminated_driver["is_active"] = False
    terminated_driver["termination_date"] = term_dt.strftime("%Y-%m-%d")

    random.seed(SEED)
    Faker.seed(SEED)
    return drivers


def write_shared_ids(drivers, vehicles, clients, zones):
    header = (
        '"""\n'
        "generators/shared_ids.py\n"
        "Auto-generated by generate_shared_ids.py — do not edit manually.\n"
        "This is the business's own master data (drivers, vehicles, clients,\n"
        "zones), independent of any of the six system generators. All six\n"
        "import from this file to keep identities consistent.\n"
        '"""\n\n'
    )
    body = (
        f"DRIVERS = {repr_py(drivers)}\n\n"
        f"VEHICLES = {repr_py(vehicles)}\n\n"
        f"CLIENTS = {repr_py(clients)}\n\n"
        f"ZONES = {repr_py(zones)}\n"
    )
    with open(SHARED_IDS_PATH, "w", encoding="utf-8") as fh:
        fh.write(header + body)


def main():
    print("SwiftRoute — shared_ids.py generator (master data, step 0)")
    print("=" * 60)

    zones    = build_zones()
    clients  = build_clients()
    vehicles = build_vehicles()
    drivers  = build_drivers(vehicles)

    write_shared_ids(drivers, vehicles, clients, zones)

    terminated = [d for d in drivers if not d["is_active"]]
    print(f"Zones     : {len(zones)}")
    print(f"Clients   : {len(clients)}  ({sum(1 for c in clients if c['is_fulfillment'])} fulfillment)")
    print(f"Vehicles  : {len(vehicles)}  ({sum(1 for v in vehicles if not v['is_active'])} out of service)")
    print(f"Drivers   : {len(drivers)}  "
          f"({sum(1 for d in drivers if d['employment_type']=='FTE')} FTE, "
          f"{sum(1 for d in drivers if d['employment_type']=='IC')} IC)")
    print(f"Terminated driver(s): {[(d['full_name'], d['termination_date']) for d in terminated]}")
    print()
    print(f"shared_ids.py written to {SHARED_IDS_PATH}")


if __name__ == "__main__":
    main()