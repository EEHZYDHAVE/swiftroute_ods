"""
generators/generate_gusto.py

Generates synthetic Gusto API responses for SwiftRoute Logistics.
Mirrors the real Gusto v1 API JSON structure from two endpoints:

  GET /v1/companies/{uuid}/employees   → full employee roster
  GET /v1/companies/{uuid}/payrolls    → bi-weekly payroll runs

Gusto API characteristics (different from all previous systems):
  - No pagination on employees — all records returned in one response
  - One JSON file per payroll run, not paginated pages
  - All monetary values are STRINGS ("2500.00" not 2500.00)
  - UUIDs everywhere — no integer IDs
  - Payrolls filterable by start_date / end_date query params

Quirks intentionally reproduced:
  1. Pay not linked to delivery count — Gusto knows nothing about Onfleet
  2. Bonuses live in variable_compensations, separate from fixed pay
  3. check_date lags period end_date by 5-7 days (timing mismatch)
  4. Gusto UUID ≠ Onfleet worker ID — cross-system mapping required
  5. Terminated employees appear in early payrolls, absent from later ones
  6. True employer cost = gross_pay + employer_taxes = company_debit

Output:
  data/raw/gusto/employees/employees.json
  data/raw/gusto/payrolls/payroll_{check_date}.json   (13 files)

Period: 2025-01-01 to 2025-06-30  (13 bi-weekly payrolls)
"""

import json
import os
import random
import uuid
from datetime import datetime, timedelta, timezone
from faker import Faker

# ── Reproducibility ────────────────────────────────────────────────────────────
SEED = 42
random.seed(SEED)
fake = Faker()
Faker.seed(SEED)

# ── Paths ──────────────────────────────────────────────────────────────────────
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT_BASE  = os.path.join(PROJECT_ROOT, "data", "raw", "gusto")

# ── Company constants ──────────────────────────────────────────────────────────
COMPANY_UUID = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
COMPANY_ID   = "8847392"

# ── Bi-weekly pay periods for Jan 1 – Jun 30, 2025 ────────────────────────────
# (period_start, period_end, check_date)
# QUIRK 3: check_date always lags period_end by 5-7 days
PAY_PERIODS = [
    ("2025-01-01", "2025-01-14", "2025-01-17"),
    ("2025-01-15", "2025-01-28", "2025-01-31"),
    ("2025-01-29", "2025-02-11", "2025-02-14"),
    ("2025-02-12", "2025-02-25", "2025-02-28"),
    ("2025-02-26", "2025-03-11", "2025-03-14"),
    ("2025-03-12", "2025-03-25", "2025-03-28"),
    ("2025-03-26", "2025-04-08", "2025-04-11"),
    ("2025-04-09", "2025-04-22", "2025-04-25"),
    ("2025-04-23", "2025-05-06", "2025-05-09"),
    ("2025-05-07", "2025-05-20", "2025-05-23"),
    ("2025-05-21", "2025-06-03", "2025-06-06"),
    ("2025-06-04", "2025-06-17", "2025-06-20"),
    ("2025-06-18", "2025-06-30", "2025-07-03"),  # check issued after sim window
]

# ── Department definitions ─────────────────────────────────────────────────────
DEPARTMENTS = {
    "Operations & Dispatch": {
        "count": 8,
        "titles": ["Dispatcher", "Senior Dispatcher", "City Operations Manager"],
        "salary_range": (42000, 68000),
        "is_driver": False,
    },
    "Drivers — Denver FTE": {
        "count": 22,
        "titles": ["Delivery Driver", "Senior Delivery Driver", "CDL Driver"],
        "salary_range": (38000, 62000),
        "is_driver": True,
        "bonus_max": 400,
    },
    "Drivers — SLC FTE": {
        "count": 7,
        "titles": ["Delivery Driver", "Senior Delivery Driver"],
        "salary_range": (40000, 52000),
        "is_driver": True,
        "bonus_max": 350,
    },
    "Drivers — ABQ FTE": {
        "count": 3,
        "titles": ["Delivery Driver"],
        "salary_range": (38000, 48000),
        "is_driver": True,
        "bonus_max": 300,
    },
    "Warehouse": {
        "count": 9,
        "titles": ["Warehouse Associate", "Senior Warehouse Associate",
                   "Warehouse Director"],
        "salary_range": (36000, 72000),
        "is_driver": False,
    },
    "Customer Support": {
        "count": 4,
        "titles": ["Support Agent", "Senior Support Agent"],
        "salary_range": (38000, 52000),
        "is_driver": False,
    },
    "Finance": {
        "count": 2,
        "titles": ["Finance Officer", "Finance Director"],
        "salary_range": (55000, 95000),
        "is_driver": False,
    },
    "Sales & BD": {
        "count": 3,
        "titles": ["Account Manager", "Head of Sales & BD"],
        "salary_range": (52000, 110000),
        "is_driver": False,
    },
    "Leadership": {
        "count": 4,
        "titles": ["VP of Operations", "CEO", "Fleet Manager",
                   "City Operations Manager — SLC"],
        "salary_range": (95000, 185000),
        "is_driver": False,
    },
}

# Total: 8+22+7+3+9+4+2+3+4 = 62 employees

# ── Employer tax rate ──────────────────────────────────────────────────────────
# Federal FICA employer share (7.65%) + FUTA (0.6%) + state avg (2.7%)
EMPLOYER_TAX_RATE = 0.0765 + 0.006 + 0.027   # 10.95%

# ══════════════════════════════════════════════════════════════════════════════
#  HELPERS
# ══════════════════════════════════════════════════════════════════════════════

def gusto_uuid():
    return str(uuid.uuid4())

def money(amount):
    """QUIRK: Gusto returns ALL monetary values as strings, not numbers."""
    return f"{amount:.2f}"

# ══════════════════════════════════════════════════════════════════════════════
#  EMPLOYEE BUILDER
# ══════════════════════════════════════════════════════════════════════════════

def build_employees():
    """
    62 FTE employees. IC drivers are NOT in Gusto — they appear only
    in QuickBooks as vendor payments.

    QUIRK 4: Gusto assigns its own UUID to each employee. The Onfleet
    worker ID is completely different. We embed a custom_field with
    the Onfleet worker ID for driver employees to simulate the mapping
    a real practitioner would need to build.

    QUIRK 5: Two employees are terminated mid-simulation. They show up
    in early payrolls and disappear from later ones without any flag in
    the earlier payroll records — you only know they left by checking
    their termination_date on the employee record.
    """
    random.seed(500)
    Faker.seed(500)

    employees    = []
    driver_index = 0

    # Simulated Onfleet worker IDs for FTE drivers
    # These mirror the IDs that generate_onfleet.py assigns to FTE drivers
    onfleet_ids = [f"drv_fte_{str(i).zfill(3)}" for i in range(1, 36)]

    for dept_name, spec in DEPARTMENTS.items():
        for i in range(spec["count"]):
            annual_sal = random.randint(*spec["salary_range"])
            bi_weekly  = round(annual_sal / 26, 2)

            emp = {
                "uuid":         gusto_uuid(),
                "first_name":   fake.first_name(),
                "last_name":    fake.last_name(),
                "email":        fake.email(),
                "company_uuid": COMPANY_UUID,
                "company_id":   COMPANY_ID,
                "department":   dept_name,
                "job": {
                    "title":          random.choice(spec["titles"]),
                    "rate":           money(bi_weekly),
                    "payment_unit":   "Paycheck",
                    "hire_date":      (datetime(2024, 1, 1) - timedelta(
                                          days=random.randint(0, 1460))
                                      ).strftime("%Y-%m-%d"),
                },
                "employment_status": "Active",
                "termination_date":  None,
                "phone":        fake.phone_number(),
                "date_of_birth": fake.date_of_birth(
                    minimum_age=21, maximum_age=58).isoformat(),
                "custom_fields": [],
                # Internal fields used during generation (not in real API)
                "_annual_salary":    annual_sal,
                "_bi_weekly_gross":  bi_weekly,
                "_dept":             dept_name,
                "_is_driver":        spec["is_driver"],
                "_bonus_max":        spec.get("bonus_max", 0),
            }

            # Attach Onfleet worker ID for FTE drivers (QUIRK 4)
            if spec["is_driver"] and driver_index < len(onfleet_ids):
                emp["custom_fields"].append({
                    "id":    "cf_onfleet_worker_id",
                    "label": "Onfleet Worker ID",
                    "value": onfleet_ids[driver_index],
                    "_note": ("QUIRK 4: this mapping does not exist natively "
                              "in either system — it must be maintained manually "
                              "or via a reference table in the ODS."),
                })
                driver_index += 1

            employees.append(emp)

    # Mark 2 employees as terminated mid-simulation (QUIRK 5)
    # Pick from non-leadership pool so the impact is meaningful but not critical
    eligible = [e for e in employees
                if e["_dept"] not in ("Leadership", "Finance", "Sales & BD")]
    for emp in random.sample(eligible, 2):
        term_dt = datetime(2025, random.randint(2, 4), random.randint(1, 25))
        emp["termination_date"]  = term_dt.strftime("%Y-%m-%d")
        emp["employment_status"] = "Terminated"

    random.seed(SEED)
    Faker.seed(SEED)
    return employees


# ══════════════════════════════════════════════════════════════════════════════
#  PAYROLL BUILDER
# ══════════════════════════════════════════════════════════════════════════════

def is_active_in_period(emp, period_end):
    """Return True if employee was still employed at the period end date."""
    if emp["termination_date"] is None:
        return True
    term = datetime.strptime(emp["termination_date"], "%Y-%m-%d")
    pend = datetime.strptime(period_end, "%Y-%m-%d")
    return term >= pend


def make_payroll(period_tuple, employees, period_index):
    """
    Build one bi-weekly payroll run as Gusto would return it.

    QUIRK 1: employee_compensations show gross pay per employee but
    contain ZERO information about how many deliveries each driver
    made. Connecting labour cost to operational output requires joining
    this data with Onfleet — a join that does not exist natively.

    QUIRK 2: performance bonuses are in variable_compensations.
    Summing only fixed_compensations gives an understated labour cost.

    QUIRK 6: company_debit = gross_pay + employer_taxes.
    net_pay is what lands in the employee's bank account.
    company_debit is what leaves SwiftRoute's account.
    """
    start, end, check = period_tuple
    payroll_uuid = gusto_uuid()

    # Only include employees active during this period
    active = [e for e in employees if is_active_in_period(e, end)]

    # Bonuses paid on second payroll of each month (odd index = second fortnight)
    is_bonus_period = (period_index % 2 == 1)

    total_gross    = 0.0
    total_net      = 0.0
    total_emp_tax  = 0.0
    total_er_tax   = 0.0
    total_deduct   = 0.0
    compensations  = []

    for emp in active:
        base_gross = emp["_bi_weekly_gross"]

        # Employee-side deductions (health insurance, 401k)
        health_deduct = round(base_gross * random.uniform(0.025, 0.055), 2)
        k401_deduct   = round(base_gross * 0.03, 2)
        total_deduct_ = health_deduct + k401_deduct

        # Employee FICA taxes (~14.35% of gross)
        emp_fica = round(base_gross * 0.1435, 2)

        # Net pay
        net = round(base_gross - emp_fica - total_deduct_, 2)

        # Employer taxes on base pay
        er_tax = round(base_gross * EMPLOYER_TAX_RATE, 2)

        # QUIRK 2: Performance bonus for eligible drivers
        variable_comps = []
        bonus_gross = 0.0
        if (is_bonus_period
                and emp["_is_driver"]
                and emp["_bonus_max"] > 0
                and random.random() < 0.65):   # 65% of drivers hit threshold

            bonus = round(
                random.uniform(emp["_bonus_max"] * 0.3, emp["_bonus_max"]), 2)
            bonus_gross = bonus
            bonus_tax   = round(bonus * 0.1435, 2)

            variable_comps.append({
                "name":     "Performance Bonus",
                "amount":   money(bonus),
                "job_uuid": gusto_uuid(),
                "_note": ("QUIRK 2: this bonus is NOT included in "
                          "fixed_compensations. Sum both arrays for "
                          "true labour cost."),
            })
            net    += round(bonus - bonus_tax - round(bonus * 0.03, 2), 2)
            emp_fica += bonus_tax
            er_tax   += round(bonus * EMPLOYER_TAX_RATE, 2)

        period_gross = base_gross + bonus_gross
        total_gross  += period_gross
        total_net    += net
        total_emp_tax += emp_fica
        total_er_tax  += er_tax
        total_deduct  += total_deduct_

        compensations.append({
            "employee_uuid": emp["uuid"],
            # QUIRK 4: only UUID here — no Onfleet worker ID
            "employee_first_name": emp["first_name"],
            "employee_last_name":  emp["last_name"],
            "department":          emp["_dept"],
            "fixed_compensations": [{
                "name":     "Regular Pay",
                "amount":   money(base_gross),
                "job_uuid": gusto_uuid(),
            }],
            "variable_compensations": variable_comps,
            "paid_time_off": [],
            "benefits": [{
                "name":                  "Medical Insurance",
                "employee_deduction":    money(health_deduct),
                "company_contribution":  money(round(health_deduct * 0.65, 2)),
                "imputed":               False,
            }],
            "employee_deductions": [{
                "name":    "401(k) Employee Contribution",
                "amount":  money(k401_deduct),
                "pre_tax": True,
            }],
            "taxes": [
                {"name": "Federal Income Tax",    "employer": False,
                 "amount": money(round(emp_fica * 0.55, 2))},
                {"name": "Social Security",       "employer": False,
                 "amount": money(round(emp_fica * 0.30, 2))},
                {"name": "Medicare",              "employer": False,
                 "amount": money(round(emp_fica * 0.15, 2))},
            ],
            # QUIRK 1 reminder embedded for practitioner discovery
            "_ods_note": (
                "Labour cost for this employee this period: "
                f"${period_gross:.2f} gross + ${er_tax:.2f} employer taxes "
                f"= ${period_gross + er_tax:.2f} true cost. "
                "Delivery count must be sourced from Onfleet — "
                "it does not exist anywhere in this file."
            ),
        })

    company_debit = round(total_gross + total_er_tax, 2)   # QUIRK 6

    return {
        "uuid":            payroll_uuid,
        "company_uuid":    COMPANY_UUID,
        "company_id":      COMPANY_ID,
        "version":         gusto_uuid(),
        "payroll_deadline": check,
        "check_date":      check,
        "processed":       True,
        "pay_period": {
            "start_date": start,
            "end_date":   end,
            "_note": (
                f"QUIRK 3: period ended {end} but money leaves accounts "
                f"on {check}. Use end_date to match labour to delivery "
                f"periods in Onfleet. Use check_date for cash flow."
            ),
        },
        "totals": {
            # QUIRK 6: company_debit is the real cost; most practitioners
            # only look at gross_pay and understate labour cost by ~11%
            "company_debit":       money(company_debit),
            "gross_pay":           money(round(total_gross, 2)),
            "net_pay":             money(round(total_net,   2)),
            "employee_taxes":      money(round(total_emp_tax, 2)),
            "employer_taxes":      money(round(total_er_tax,  2)),
            "employee_deductions": money(round(total_deduct,  2)),
            "_note": (
                f"QUIRK 6: company_debit ({money(company_debit)}) = "
                f"gross_pay ({money(round(total_gross,2))}) + "
                f"employer_taxes ({money(round(total_er_tax,2))}). "
                "Use company_debit for true cost-per-delivery calculations."
            ),
        },
        "employee_compensations": compensations,
    }


# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════

def main():
    print("SwiftRoute — Gusto raw data generator")
    print("=" * 45)

    employees  = build_employees()
    terminated = [e for e in employees if e["termination_date"]]
    drivers    = [e for e in employees if e["_is_driver"]]

    print(f"Employees total  : {len(employees)}")
    print(f"  FTE drivers    : {len(drivers)}")
    print(f"  Terminated     : {len(terminated)}  ← QUIRK 5")
    for t in terminated:
        print(f"    {t['first_name']} {t['last_name']} "
              f"({t['_dept']}) — term date: {t['termination_date']}")
    print(f"Pay periods      : {len(PAY_PERIODS)} bi-weekly")
    print()

    # ── Write employees — single file, no pagination ───────────────────────────
    emp_folder = os.path.join(OUTPUT_BASE, "employees")
    os.makedirs(emp_folder, exist_ok=True)
    with open(os.path.join(emp_folder, "employees.json"),
              "w", encoding="utf-8") as fh:
        json.dump(employees, fh, indent=2, ensure_ascii=False)
    print("Employees written to employees/employees.json")
    print()

    # ── Write one payroll file per pay period ──────────────────────────────────
    payroll_folder = os.path.join(OUTPUT_BASE, "payrolls")
    os.makedirs(payroll_folder, exist_ok=True)

    print("Generating payrolls...")
    total_debit  = 0.0
    total_bonuses = 0

    for idx, period in enumerate(PAY_PERIODS):
        start, end, check = period
        payroll  = make_payroll(period, employees, idx)
        filename = f"payroll_{check}.json"

        with open(os.path.join(payroll_folder, filename),
                  "w", encoding="utf-8") as fh:
            json.dump(payroll, fh, indent=2, ensure_ascii=False)

        debit       = float(payroll["totals"]["company_debit"])
        gross       = float(payroll["totals"]["gross_pay"])
        er_taxes    = float(payroll["totals"]["employer_taxes"])
        active_ct   = len(payroll["employee_compensations"])
        bonus_ct    = sum(1 for ec in payroll["employee_compensations"]
                          if ec["variable_compensations"])

        total_debit   += debit
        total_bonuses += bonus_ct

        print(f"  {start} → {end}  check:{check}  "
              f"{active_ct:>2} employees  "
              f"gross:${gross:>9,.2f}  "
              f"debit:${debit:>9,.2f}  "
              f"bonuses:{bonus_ct}")

    print()
    print("=" * 45)
    print(f"Total employees     : {len(employees)}")
    print(f"Total pay periods   : {len(PAY_PERIODS)}")
    print(f"Total company debit : ${total_debit:,.2f}  (gross + employer taxes)")
    print(f"Total bonus events  : {total_bonuses}")
    print(f"Output              : {OUTPUT_BASE}")
    print()
    print("Quirks to find when you open these files:")
    print("  1. All money values are strings — '2500.00' not 2500.00")
    print("  2. No pagination — employees.json has all 62 records")
    print("  3. One payroll file per period, named by check_date")
    print("  4. check_date lags period end_date by several days")
    print("  5. variable_compensations separate from fixed_compensations")
    print("  6. company_debit > gross_pay (employer taxes)")
    print("  7. Terminated employees absent from later payroll files")


if __name__ == "__main__":
    main()
