"""
generators/generate_gusto.py

Generates synthetic Gusto API responses for SwiftRoute Logistics.
Imports DRIVERS from shared_ids.py (written by generate_shared_ids.py,
which must run first) — Gusto does not originate any shared identity,
it only consumes it and reshapes it into Gusto's own API structure.

Gusto only knows about FTE employees. IC drivers are excluded entirely
from this file's output (they appear only in QuickBooks as vendor pay).

Quirks reproduced:
  1. Pay not linked to delivery count — Gusto knows nothing about Onfleet
  2. Bonuses live in variable_compensations, separate from fixed pay
  3. check_date lags period end_date by 5-7 days
  4. Gusto UUID != Onfleet worker ID — cross-system mapping required
  5. Terminated employees appear in early payrolls, absent from later ones
  6. company_debit = gross_pay + employer_taxes

Output:
  source_data/raw/gusto/employees/employees.json
  source_data/raw/gusto/payrolls/payroll_{check_date}.json   (13 files)

Period: 2025-01-01 to 2025-06-30
SEED = 42
"""

import json
import os
import random
from datetime import datetime, timedelta
import uuid
from faker import Faker

import shared_ids

SEED = 42
random.seed(SEED)
fake = Faker()
Faker.seed(SEED)

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT_BASE  = os.path.join(PROJECT_ROOT, "source_data", "raw", "gusto")   # unchanged, per instruction

COMPANY_UUID = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
COMPANY_ID   = "8847392"
EMPLOYER_TAX_RATE = 0.0765 + 0.006 + 0.027   # 10.95%

NON_DRIVER_DEPARTMENTS = {
    "Operations & Dispatch": {"count": 8, "titles": ["Dispatcher", "Senior Dispatcher", "City Operations Manager"], "salary_range": (42000, 68000)},
    "Warehouse":             {"count": 9, "titles": ["Warehouse Associate", "Senior Warehouse Associate", "Warehouse Director"], "salary_range": (36000, 72000)},
    "Customer Support":      {"count": 4, "titles": ["Support Agent", "Senior Support Agent"], "salary_range": (38000, 52000)},
    "Finance":               {"count": 2, "titles": ["Finance Officer", "Finance Director"], "salary_range": (55000, 95000)},
    "Sales & BD":            {"count": 3, "titles": ["Account Manager", "Head of Sales & BD"], "salary_range": (52000, 110000)},
    "Leadership":            {"count": 4, "titles": ["VP of Operations", "CEO", "Fleet Manager", "City Operations Manager — SLC"], "salary_range": (95000, 185000)},
}
# 8+9+4+2+3+4 = 30 non-driver staff. + 32 FTE drivers = 62 total employees.

DRIVER_TITLES = ["Delivery Driver", "Senior Delivery Driver", "CDL Driver"]
DRIVER_BONUS_MAX = {"denver": 400, "salt_lake_city": 350, "albuquerque": 300}

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
    ("2025-06-18", "2025-06-30", "2025-07-03"),
]


def gusto_uuid():
    return str(uuid.uuid4())

def money(amount):
    return f"{amount:.2f}"


# ══════════════════════════════════════════════════════════════════════════
#  EMPLOYEE BUILDER — sourced from shared_ids.DRIVERS + local non-driver staff
# ══════════════════════════════════════════════════════════════════════════

def build_employees():
    """62 FTE employees = 32 FTE drivers (from shared_ids.DRIVERS, IC
    excluded) + 30 non-driver staff (generated here, since they aren't
    shared business entities across systems).

    QUIRK 5, part 1: a Denver FTE driver's termination is already baked
    into shared_ids.DRIVERS (decided independently of Gusto) — we just
    inherit it here.
    QUIRK 5, part 2: exactly one additional non-driver employee is
    terminated, scoped to Gusto only.
    """
    random.seed(500)
    Faker.seed(500)

    employees = []

    fte_drivers = [d for d in shared_ids.DRIVERS if d["employment_type"] == "FTE"]
    for d in fte_drivers:
        employees.append({
            "uuid":         d["gusto_uuid"],
            "first_name":   d["first_name"],
            "last_name":    d["last_name"],
            "email":        d["email"],
            "company_uuid": COMPANY_UUID,
            "company_id":   COMPANY_ID,
            "department":   d["department"],
            "job": {
                "title":        random.choice(DRIVER_TITLES),
                "rate":         money(d["bi_weekly_gross"]),
                "payment_unit": "Paycheck",
                "hire_date":    d["hire_date"],
            },
            "employment_status": "Terminated" if not d["is_active"] else "Active",
            "termination_date":  d["termination_date"],
            "phone":        fake.phone_number(),
            "date_of_birth": fake.date_of_birth(minimum_age=21, maximum_age=58).isoformat(),
            "custom_fields": [{
                "id":    "cf_onfleet_worker_id",
                "label": "Onfleet Worker ID",
                "value": d["onfleet_worker_id"],
                "_note": ("QUIRK 4: this mapping does not exist natively in "
                          "either system — it must be maintained manually or "
                          "via a reference table in the ODS."),
            }],
            "_annual_salary":   d["annual_salary"],
            "_bi_weekly_gross": d["bi_weekly_gross"],
            "_dept":            d["department"],
            "_is_driver":       True,
            "_bonus_max":       DRIVER_BONUS_MAX[d["city"]],
        })

    for dept_name, spec in NON_DRIVER_DEPARTMENTS.items():
        for _ in range(spec["count"]):
            annual_sal = random.randint(*spec["salary_range"])
            bi_weekly  = round(annual_sal / 26, 2)
            employees.append({
                "uuid":         gusto_uuid(),
                "first_name":   fake.first_name(),
                "last_name":    fake.last_name(),
                "email":        fake.email(),
                "company_uuid": COMPANY_UUID,
                "company_id":   COMPANY_ID,
                "department":   dept_name,
                "job": {
                    "title":        random.choice(spec["titles"]),
                    "rate":         money(bi_weekly),
                    "payment_unit": "Paycheck",
                    "hire_date":    (datetime(2024, 1, 1) - timedelta(days=random.randint(0, 1460))).strftime("%Y-%m-%d"),
                },
                "employment_status": "Active",
                "termination_date":  None,
                "phone":        fake.phone_number(),
                "date_of_birth": fake.date_of_birth(minimum_age=21, maximum_age=58).isoformat(),
                "custom_fields": [],
                "_annual_salary":   annual_sal,
                "_bi_weekly_gross": bi_weekly,
                "_dept":            dept_name,
                "_is_driver":       False,
                "_bonus_max":       0,
            })

    # QUIRK 5, part 2: one additional termination, non-driver only
    # (driver termination already inherited from shared_ids above)
    eligible = [e for e in employees
                if not e["_is_driver"] and e["_dept"] not in ("Leadership", "Finance", "Sales & BD")]
    staff_terminated = random.choice(eligible)
    term_dt = datetime(2025, random.randint(2, 4), random.randint(1, 25))
    staff_terminated["termination_date"]  = term_dt.strftime("%Y-%m-%d")
    staff_terminated["employment_status"] = "Terminated"

    random.seed(SEED)
    Faker.seed(SEED)
    return employees


# ══════════════════════════════════════════════════════════════════════════
#  PAYROLL BUILDER
# ══════════════════════════════════════════════════════════════════════════

def is_active_in_period(emp, period_end):
    if emp["termination_date"] is None:
        return True
    term = datetime.strptime(emp["termination_date"], "%Y-%m-%d")
    pend = datetime.strptime(period_end, "%Y-%m-%d")
    return term >= pend


def make_payroll(period_tuple, employees, period_index):
    start, end, check = period_tuple
    payroll_uuid = gusto_uuid()
    active = [e for e in employees if is_active_in_period(e, end)]
    is_bonus_period = (period_index % 2 == 1)

    total_gross = total_net = total_emp_tax = total_er_tax = total_deduct = 0.0
    compensations = []

    for emp in active:
        base_gross = emp["_bi_weekly_gross"]
        health_deduct = round(base_gross * random.uniform(0.025, 0.055), 2)
        k401_deduct   = round(base_gross * 0.03, 2)
        total_deduct_ = health_deduct + k401_deduct
        emp_fica = round(base_gross * 0.1435, 2)
        net = round(base_gross - emp_fica - total_deduct_, 2)
        er_tax = round(base_gross * EMPLOYER_TAX_RATE, 2)

        variable_comps = []
        bonus_gross = 0.0
        if is_bonus_period and emp["_is_driver"] and emp["_bonus_max"] > 0 and random.random() < 0.65:
            bonus = round(random.uniform(emp["_bonus_max"] * 0.3, emp["_bonus_max"]), 2)
            bonus_gross = bonus
            bonus_tax = round(bonus * 0.1435, 2)
            variable_comps.append({
                "name": "Performance Bonus",
                "amount": money(bonus),
                "job_uuid": gusto_uuid(),
                "_note": "QUIRK 2: not in fixed_compensations. Sum both arrays for true labour cost.",
            })
            net += round(bonus - bonus_tax - round(bonus * 0.03, 2), 2)
            emp_fica += bonus_tax
            er_tax += round(bonus * EMPLOYER_TAX_RATE, 2)

        period_gross = base_gross + bonus_gross
        total_gross += period_gross
        total_net += net
        total_emp_tax += emp_fica
        total_er_tax += er_tax
        total_deduct += total_deduct_

        compensations.append({
            "employee_uuid": emp["uuid"],
            "employee_first_name": emp["first_name"],
            "employee_last_name": emp["last_name"],
            "department": emp["_dept"],
            "fixed_compensations": [{"name": "Regular Pay", "amount": money(base_gross), "job_uuid": gusto_uuid()}],
            "variable_compensations": variable_comps,
            "paid_time_off": [],
            "benefits": [{
                "name": "Medical Insurance",
                "employee_deduction": money(health_deduct),
                "company_contribution": money(round(health_deduct * 0.65, 2)),
                "imputed": False,
            }],
            "employee_deductions": [{"name": "401(k) Employee Contribution", "amount": money(k401_deduct), "pre_tax": True}],
            "taxes": [
                {"name": "Federal Income Tax", "employer": False, "amount": money(round(emp_fica * 0.55, 2))},
                {"name": "Social Security",    "employer": False, "amount": money(round(emp_fica * 0.30, 2))},
                {"name": "Medicare",           "employer": False, "amount": money(round(emp_fica * 0.15, 2))},
            ],
            "_ods_note": (
                f"Labour cost for this employee this period: ${period_gross:.2f} gross + "
                f"${er_tax:.2f} employer taxes = ${period_gross + er_tax:.2f} true cost. "
                "Delivery count must be sourced from Onfleet — it does not exist anywhere in this file."
            ),
        })

    company_debit = round(total_gross + total_er_tax, 2)
    return {
        "uuid": payroll_uuid,
        "company_uuid": COMPANY_UUID,
        "company_id": COMPANY_ID,
        "version": gusto_uuid(),
        "payroll_deadline": check,
        "check_date": check,
        "processed": True,
        "pay_period": {
            "start_date": start, "end_date": end,
            "_note": f"QUIRK 3: period ended {end} but money leaves accounts on {check}.",
        },
        "totals": {
            "company_debit": money(company_debit),
            "gross_pay": money(round(total_gross, 2)),
            "net_pay": money(round(total_net, 2)),
            "employee_taxes": money(round(total_emp_tax, 2)),
            "employer_taxes": money(round(total_er_tax, 2)),
            "employee_deductions": money(round(total_deduct, 2)),
            "_note": "QUIRK 6: company_debit = gross_pay + employer_taxes.",
        },
        "employee_compensations": compensations,
    }


# ══════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════

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
        print(f"    {t['first_name']} {t['last_name']} ({t['_dept']}) — term date: {t['termination_date']}")
    print(f"Pay periods      : {len(PAY_PERIODS)} bi-weekly")
    print()

    emp_folder = os.path.join(OUTPUT_BASE, "employees")
    os.makedirs(emp_folder, exist_ok=True)
    with open(os.path.join(emp_folder, "employees.json"), "w", encoding="utf-8") as fh:
        json.dump(employees, fh, indent=2, ensure_ascii=False)
    print("Employees written to employees/employees.json")
    print()

    payroll_folder = os.path.join(OUTPUT_BASE, "payrolls")
    os.makedirs(payroll_folder, exist_ok=True)

    print("Generating payrolls...")
    total_debit = 0.0
    for idx, period in enumerate(PAY_PERIODS):
        start, end, check = period
        payroll = make_payroll(period, employees, idx)
        with open(os.path.join(payroll_folder, f"payroll_{check}.json"), "w", encoding="utf-8") as fh:
            json.dump(payroll, fh, indent=2, ensure_ascii=False)
        debit = float(payroll["totals"]["company_debit"])
        total_debit += debit
        print(f"  {start} → {end}  check:{check}  "
              f"{len(payroll['employee_compensations']):>2} employees  debit:${debit:>9,.2f}")

    print()
    print("=" * 45)
    print(f"Total employees     : {len(employees)}")
    print(f"Total pay periods   : {len(PAY_PERIODS)}")
    print(f"Total company debit : ${total_debit:,.2f}")
    print(f"Output              : {OUTPUT_BASE}")


if __name__ == "__main__":
    main()