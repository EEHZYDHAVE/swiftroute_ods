"""
simulators/simulate_quickbooks.py

Incremental QuickBooks simulator. Two different cadences, matched to
what's realistic:
  - Expenses: generated EVERY run (a 7-day window is naturally "one
    week" of ongoing operational cost — fuel, IC driver pay, COD).
    Monthly fixed costs (rent, insurance, leasing, software) are only
    added once per calendar month, detected by scanning existing
    expense files rather than tracked in a separate state file.
  - Invoices + payments: only generated when this run's window causes a
    calendar month to become FULLY complete that hasn't been invoiced
    yet — matches the historical one-invoice-per-client-per-month
    cadence. Most weekly runs will produce none of these, which is
    correct (billing is monthly, not continuous).
"""

import os
import sys
import json
import glob
import random
import argparse
from datetime import datetime, timedelta, timezone
import calendar

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "generators"))

import _common
import shared_ids
import generate_quickbooks as qb

SEED = 42


def latest_invoiced_period():
    """Scans existing invoices for the latest 'Billing Period' custom
    field value (e.g. '2025-06'). Returns (year, month) or None."""
    latest = None
    for f in glob.glob(_common.system_path("quickbooks", "invoices", "page_*.json")):
        with open(f) as fh:
            payload = json.load(fh)
        for inv in payload["QueryResponse"]["Invoice"]:
            period_str = inv["CustomField"][1]["StringValue"]
            y, m = period_str.split("-")
            key = (int(y), int(m))
            if latest is None or key > latest:
                latest = key
    return latest


def month_fully_elapsed(year, month, as_of_date):
    last_day = calendar.monthrange(year, month)[1]
    return as_of_date >= datetime(year, month, last_day).date()


def next_month(year, month):
    return (year + 1, 1) if month == 12 else (year, month + 1)


def has_fixed_costs_this_month(year, month):
    """Checks whether the monthly fixed-cost bundle (rent, insurance,
    etc.) has already been written for this calendar month, by scanning
    existing expense files for a Warehouse Rent entry in that month."""
    for f in glob.glob(_common.system_path("quickbooks", "expenses", "page_*.json")):
        with open(f) as fh:
            payload = json.load(fh)
        for exp in payload["QueryResponse"]["Purchase"]:
            if exp["AccountRef"]["name"] != "Warehouse Rent":
                continue
            txn_date = datetime.strptime(exp["TxnDate"], "%Y-%m-%d")
            if txn_date.year == year and txn_date.month == month:
                return True
    return False


def write_qb_pages(records, folder, entity_name):
    if not records:
        return 0
    start_page = _common.next_page_number(folder)
    pages = [records[i:i + qb.PAGE_SIZE] for i in range(0, len(records), qb.PAGE_SIZE)]
    total = len(records)
    for i, page in enumerate(pages):
        start_pos = (start_page + i - 1) * qb.PAGE_SIZE + 1
        payload = qb.qbo_page(entity_name, page, start_pos, total)
        _common.write_json(os.path.join(folder, f"page_{str(start_page + i).zfill(4)}.json"), payload)
    return len(pages)


def run(start_date, end_date):
    print(f"[quickbooks] simulating {start_date} -> {end_date}")
    random.seed(SEED)

    clients = qb.build_qb_clients()
    ic_driver_count = sum(1 for d in shared_ids.DRIVERS if d["employment_type"] == "IC")

    # ── Weekly expenses — every run ──────────────────────────────────────
    expenses = []
    week_start = datetime(start_date.year, start_date.month, start_date.day, tzinfo=timezone.utc)

    if not has_fixed_costs_this_month(start_date.year, start_date.month):
        fixed = [
            ("Warehouse Rent", 18500.00, "Denver Industrial Properties LLC", "Monthly warehouse rent — Denver WH"),
            ("Insurance", 3200.00, "Gallagher Commercial Insurance", "Fleet and liability insurance premium"),
            ("Vehicle Leasing", 8400.00, "Enterprise Fleet Management", "Monthly vehicle lease — 22 cargo vans + 4 box trucks"),
            ("Software & Technology", 890.00, "Onfleet Inc.", "TMS subscription — 48 driver seats"),
            ("Software & Technology", 420.00, "Samsara Inc.", "Fleet telematics — 34 vehicles"),
            ("Software & Technology", 310.00, "Zendesk Inc.", "Customer support platform"),
            ("Software & Technology", 175.00, "Linnworks Ltd.", "WMS subscription"),
            ("Software & Technology", 85.00, "Supabase Inc.", "Database hosting"),
        ]
        for cat, amt, vendor, note in fixed:
            exp_date = week_start + timedelta(days=random.randint(0, min(4, (end_date - start_date).days)))
            expenses.append(qb.make_expense(exp_date, cat, amt, vendor, qb.next_id(qb._exp_counter), note))
        print(f"  monthly fixed costs added for {start_date.year}-{str(start_date.month).zfill(2)}")

    for _ in range(random.randint(28, 36)):   # ~weekly slice of the historical monthly fuel volume
        exp_date = week_start + timedelta(days=random.randint(0, (end_date - start_date).days))
        if random.random() < 0.06:
            category, note = "Vehicle Maintenance", "WEX Fleet Card — fuel (miscoded)"
        else:
            category, note = "Fuel", "WEX Fleet Card — fuel"
        fuel_amt = round(random.uniform(55, 145), 2)
        expenses.append(qb.make_expense(exp_date, category, fuel_amt, "WEX Fleet Solutions", qb.next_id(qb._exp_counter), note))

    if random.random() < 0.5:
        exp_date = week_start + timedelta(days=random.randint(0, (end_date - start_date).days))
        maint_amt = round(random.uniform(120, 1800), 2)
        expenses.append(qb.make_expense(
            exp_date, "Vehicle Maintenance", maint_amt,
            random.choice(["Midas Auto Service", "Jiffy Lube Commercial", "Pep Boys Fleet", "Denver Truck Center"]),
            qb.next_id(qb._exp_counter),
            random.choice(["Oil change + tyre rotation", "Brake service", "Transmission service", "Tyre replacement", "Annual safety inspection"])))

    for driver_n in range(ic_driver_count):
        exp_date = week_start + timedelta(days=random.randint(0, 2))
        ic_pay = round(random.uniform(280, 920), 2)
        expenses.append(qb.make_expense(
            exp_date, "Driver Labour — IC", ic_pay, f"IC Driver #{str(driver_n + 1).zfill(2)}",
            qb.next_id(qb._exp_counter), f"Weekly IC driver payment — week of {start_date}"))

    cod_amt = round(random.uniform(1800, 4200), 2)
    expenses.append(qb.make_expense(
        week_start + timedelta(days=4), "General & Admin", -cod_amt, "Internal — Driver COD Remittance",
        qb.next_id(qb._exp_counter), f"COD cash remittance — week of {start_date} (~{random.randint(60,120)} deliveries, lump total)"))

    if random.random() < 0.4:
        exp_date = week_start + timedelta(days=random.randint(0, (end_date - start_date).days))
        expenses.append(qb.make_expense(
            exp_date, "Warehouse Supplies", round(random.uniform(80, 650), 2),
            random.choice(["Uline", "Staples Business", "Amazon Business"]),
            qb.next_id(qb._exp_counter),
            random.choice(["Packing tape and boxes", "Bubble wrap — bulk", "Labels and barcode rolls", "Pallet wrap"])))

    exp_pages = write_qb_pages(expenses, _common.system_path("quickbooks", "expenses"), "Purchase")
    print(f"  +{len(expenses)} expenses -> {exp_pages} new page(s)")

    # ── Invoices + payments — only when a month fully completes ─────────
    last_invoiced = latest_invoiced_period()
    if last_invoiced is None:
        raise RuntimeError("No existing QuickBooks invoices found — run the historical generators first.")

    invoices = []
    payments = []
    year, month = next_month(*last_invoiced)
    # make_payment() checks payments against qb.END_DATE, which is hardcoded
    # to the historical period end (2025-06-30) inside generate_quickbooks.py.
    # Patch it to this run's actual window so incremental payments aren't
    # silently rejected as "outside the simulation period."
    qb.END_DATE = datetime(end_date.year, end_date.month, end_date.day, tzinfo=timezone.utc)
    while month_fully_elapsed(year, month, end_date):
        print(f"  {year}-{str(month).zfill(2)} has fully elapsed — generating invoices/payments")
        for client in clients:
            inv_id = qb.next_id(qb._inv_counter)
            invoice = qb.make_invoice(client, year, month, inv_id)
            invoices.append(invoice)

            pay_id = qb.next_id(qb._pay_counter)
            payment = qb.make_payment(client, invoice, pay_id)
            if payment:
                invoice["Balance"] = round(invoice["TotalAmt"] - payment["TotalAmt"], 2)
                invoice["LinkedTxn"].append({"TxnId": pay_id, "TxnType": "Payment"})
                payments.append(payment)
        year, month = next_month(year, month)

    inv_pages = write_qb_pages(invoices, _common.system_path("quickbooks", "invoices"), "Invoice")
    pay_pages = write_qb_pages(payments, _common.system_path("quickbooks", "payments"), "Payment")
    if invoices:
        print(f"  +{len(invoices)} invoices -> {inv_pages} page(s), +{len(payments)} payments -> {pay_pages} page(s)")
    else:
        print("  no month fully elapsed this window — no invoices/payments")

    print(f"[quickbooks] done.")
    return len(expenses) + len(invoices)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--start-date", required=True)
    parser.add_argument("--end-date", required=True)
    args = parser.parse_args()
    s = datetime.strptime(args.start_date, "%Y-%m-%d").date()
    e = datetime.strptime(args.end_date, "%Y-%m-%d").date()
    run(s, e)
