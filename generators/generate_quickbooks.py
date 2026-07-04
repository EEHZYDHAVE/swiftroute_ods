"""
generators/generate_quickbooks.py

Generates synthetic QuickBooks Online API responses for SwiftRoute Logistics.
Imports CLIENTS from shared_ids.py (written by generate_shared_ids.py,
which must run first) — shared_ids.py is authoritative for client
identity AND payment_terms (net-30 baseline, exactly 2 clients on
net-60 — that quirk is decided once, at the source, not re-invented here).

Payment BEHAVIOR traits (late_pct, partial_pct, pay_channel) are
QuickBooks-specific concepts, not shared business facts, so they're
derived locally from each client's tier — not sourced from shared_ids.

Mirrors the real QBO REST API JSON structure from three query endpoints:
  SELECT * FROM Invoice   → monthly client invoices
  SELECT * FROM Payment   → payments received against invoices
  SELECT * FROM Purchase  → operating expenses (fuel, maintenance, rent, etc.)

Quirks intentionally reproduced:
  1. No delivery-level detail on invoices — forces cross-system join
  2. Partial payments — some clients consistently pay slightly short
  3. Late payments — some clients pay past the due date
  4. COD appears as lump deposit, not per-delivery
  5. Expense miscategorisation — fuel sometimes coded as Vehicle Maintenance
  6. Two clients on net-60 terms instead of net-30 (from shared_ids)

Output:
  source_data/raw/quickbooks/invoices/page_{NNNN}.json
  source_data/raw/quickbooks/payments/page_{NNNN}.json
  source_data/raw/quickbooks/expenses/page_{NNNN}.json

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
OUTPUT_BASE  = os.path.join(PROJECT_ROOT, "source_data", "raw", "quickbooks")

START_DATE = datetime(2025, 1,  1, tzinfo=timezone.utc)
END_DATE   = datetime(2025, 6, 30, tzinfo=timezone.utc)
PAGE_SIZE = 100
COMPANY_ID = "9341452837194821"

TIER_BEHAVIOR = {
    # tier: (late_pct, partial_pct, pay_channel choices)
    "platinum": (0.05, 0.03, ["ACH","ACH","ACH","CREDIT_CARD"]),
    "gold":     (0.15, 0.08, ["ACH","ACH","CREDIT_CARD","CHECK"]),
    "standard": (0.28, 0.14, ["ACH","CREDIT_CARD","CHECK","CHECK"]),
}


def build_qb_clients():
    """94 clients, sourced from shared_ids.CLIENTS — identity and
    payment_terms (including the exact-2 net-60 quirk) come straight
    from there. Only payment-behavior traits (late/partial/channel) are
    derived locally per tier, since those aren't shared business facts."""
    random.seed(400)
    clients = []
    for i, c in enumerate(shared_ids.CLIENTS, start=1):
        late_pct, partial_pct, channels = TIER_BEHAVIOR[c["tier"]]
        clients.append({
            "qb_id":        str(i),
            "internal_id":  c["internal_id"],
            "name":         c["name"],
            "tier":         c["tier"],
            "terms_days":   c["payment_terms"],
            "is_net60":     c["payment_terms"] == 60,
            "is_fulfillment": c["is_fulfillment"],
            "late_pct":     late_pct,
            "partial_pct":  partial_pct,
            "pay_channel":  random.choice(channels),
            "email":        fake.company_email(),
        })
    random.seed(SEED)
    return clients


SERVICE_ITEMS = {
    "same_day":          {"qb_item_id": "1", "name": "Same-Day Delivery", "unit_price_range": (8.50, 32.00)},
    "next_day":          {"qb_item_id": "2", "name": "Next-Day Delivery", "unit_price_range": (6.50, 24.00)},
    "scheduled":         {"qb_item_id": "3", "name": "Scheduled Window Delivery", "unit_price_range": (12.00, 28.00)},
    "fulfillment_pick":  {"qb_item_id": "4", "name": "Fulfillment — Pick & Pack", "unit_price_range": (1.80, 4.50)},
    "storage":           {"qb_item_id": "5", "name": "Warehouse Storage", "unit_price_range": (28.00, 95.00)},
    "returns":           {"qb_item_id": "6", "name": "Returns Handling", "unit_price_range": (5.00, 18.00)},
    "distribution_run":  {"qb_item_id": "7", "name": "B2B Distribution Run", "unit_price_range": (85.00, 280.00)},
}

MONTHLY_VOLUME = {"platinum": (800, 1800), "gold": (200, 800), "standard": (30, 200)}

EXPENSE_ACCOUNTS = {
    "Fuel":                  {"qb_id": "101", "type": "Expense"},
    "Vehicle Maintenance":   {"qb_id": "102", "type": "Expense"},
    "Vehicle Leasing":       {"qb_id": "103", "type": "Expense"},
    "Driver Labour — IC":    {"qb_id": "104", "type": "Expense"},
    "Warehouse Rent":        {"qb_id": "105", "type": "Expense"},
    "Warehouse Supplies":    {"qb_id": "106", "type": "Expense"},
    "Insurance":             {"qb_id": "107", "type": "Expense"},
    "Software & Technology": {"qb_id": "108", "type": "Expense"},
    "General & Admin":       {"qb_id": "109", "type": "Expense"},
}

_inv_counter = [1000]
_pay_counter = [5000]
_exp_counter = [9000]

def next_id(counter):
    counter[0] += 1
    return str(counter[0])

def qb_date(dt):
    return dt.strftime("%Y-%m-%d")

def qb_datetime(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%S-07:00")

def month_range(year, month):
    start = datetime(year, month, 1, tzinfo=timezone.utc)
    if month == 12:
        end = datetime(year+1, 1, 1, tzinfo=timezone.utc) - timedelta(days=1)
    else:
        end = datetime(year, month+1, 1, tzinfo=timezone.utc) - timedelta(days=1)
    return start, end


# ══════════════════════════════════════════════════════════════════════════
#  INVOICE GENERATOR
# ══════════════════════════════════════════════════════════════════════════

def make_invoice(client, year, month, inv_id):
    """QUIRK 1: line items show service type/qty/rate but NO delivery IDs
    — joining to Onfleet by client_id + billing period is required."""
    month_start, month_end = month_range(year, month)

    invoice_date = month_end + timedelta(days=1)
    while invoice_date.weekday() > 4:
        invoice_date += timedelta(days=1)

    due_date = invoice_date + timedelta(days=client["terms_days"])

    lo, hi = MONTHLY_VOLUME[client["tier"]]
    total_vol = random.randint(lo, hi)

    lines = []
    line_n = 1
    total = 0.0

    if client["is_fulfillment"]:
        use_types = ["fulfillment_pick", "storage"]
        if random.random() > 0.6:
            use_types.append("returns")
    else:
        use_types = ["next_day"]
        if client["tier"] in ("platinum", "gold") and random.random() > 0.3:
            use_types.append("same_day")
        if random.random() > 0.7:
            use_types.append("returns")
        if client["tier"] == "platinum" and random.random() > 0.5:
            use_types.append("distribution_run")

    remaining_vol = total_vol
    for i, svc in enumerate(use_types):
        item = SERVICE_ITEMS[svc]
        lo_r, hi_r = item["unit_price_range"]
        unit_price = round(random.uniform(lo_r, hi_r), 2)

        if i == len(use_types) - 1:
            qty = remaining_vol
        else:
            qty = max(1, int(remaining_vol * random.uniform(0.2, 0.6)))
            remaining_vol -= qty

        amount = round(qty * unit_price, 2)
        total += amount

        lines.append({
            "Id": str(line_n),
            "LineNum": line_n,
            "Description": (f"{item['name']} — {month_start.strftime('%B %Y')} ({qty} units)"),
            "Amount": amount,
            "DetailType": "SalesItemLineDetail",
            "SalesItemLineDetail": {
                "ItemRef": {"value": item["qb_item_id"], "name": item["name"]},
                "UnitPrice": unit_price,
                "Qty": qty,
                "ServiceDate": qb_date(month_end),
            },
        })
        line_n += 1

    total = round(total, 2)

    return {
        "Id": inv_id,
        "SyncToken": str(random.randint(0, 5)),
        "MetaData": {
            "CreateTime": qb_datetime(invoice_date),
            "LastUpdatedTime": qb_datetime(invoice_date + timedelta(hours=2)),
        },
        "DocNumber": f"INV-{year}-{inv_id.zfill(5)}",
        "TxnDate": qb_date(invoice_date),
        "DueDate": qb_date(due_date),
        "CustomerRef": {"value": client["qb_id"], "name": client["name"]},
        "BillEmail": {"Address": client["email"]},
        "EmailStatus": "EmailSent",
        "Line": lines,
        "TotalAmt": total,
        "Balance": total,
        "CurrencyRef": {"value": "USD", "name": "United States Dollar"},
        "PaymentMethodRef": {"value": "1", "name": client["pay_channel"]},
        "LinkedTxn": [],
        "CustomField": [
            {"DefinitionId": "1", "Name": "SwiftRoute Client ID", "Type": "StringType", "StringValue": client["internal_id"]},
            {"DefinitionId": "2", "Name": "Billing Period", "Type": "StringType", "StringValue": f"{year}-{str(month).zfill(2)}"},
            {"DefinitionId": "3", "Name": "Payment Terms", "Type": "StringType", "StringValue": f"Net {client['terms_days']}"},
        ],
    }


# ══════════════════════════════════════════════════════════════════════════
#  PAYMENT GENERATOR
# ══════════════════════════════════════════════════════════════════════════

def make_payment(client, invoice, pay_id):
    inv_total = invoice["TotalAmt"]
    due_date = datetime.strptime(invoice["DueDate"], "%Y-%m-%d")
    inv_date = datetime.strptime(invoice["TxnDate"], "%Y-%m-%d")

    if random.random() < 0.04:
        return None

    if random.random() < client["late_pct"]:
        pay_date = due_date + timedelta(days=random.randint(5, 35))
    else:
        pay_date = due_date - timedelta(days=random.randint(0, 5))

    if pay_date.replace(tzinfo=timezone.utc) > END_DATE:
        return None

    if random.random() < client["partial_pct"]:
        pay_amount = round(inv_total * random.uniform(0.93, 0.99), 2)
    else:
        pay_amount = inv_total

    unapplied = round(inv_total - pay_amount, 2)

    return {
        "Id": pay_id,
        "SyncToken": "0",
        "MetaData": {"CreateTime": qb_datetime(pay_date), "LastUpdatedTime": qb_datetime(pay_date)},
        "TxnDate": qb_date(pay_date),
        "CustomerRef": {"value": client["qb_id"], "name": client["name"]},
        "TotalAmt": pay_amount,
        "UnappliedAmt": unapplied,
        "ProcessPayment": False,
        "PaymentMethodRef": {"value": "1", "name": client["pay_channel"]},
        "DepositToAccountRef": {"value": "35", "name": "Checking — GTBank Business"},
        "Line": [{"Amount": pay_amount, "LinkedTxn": [{"TxnId": invoice["Id"], "TxnType": "Invoice"}]}],
        "CustomField": [
            {"DefinitionId": "1", "Name": "SwiftRoute Client ID", "Type": "StringType", "StringValue": client["internal_id"]},
            {"DefinitionId": "4", "Name": "Days to Pay", "Type": "StringType", "StringValue": str((pay_date - inv_date).days)},
        ],
    }


# ══════════════════════════════════════════════════════════════════════════
#  EXPENSE GENERATOR
# ══════════════════════════════════════════════════════════════════════════

def make_expense(exp_date, category, amount, vendor, exp_id, note=""):
    account = EXPENSE_ACCOUNTS.get(category, EXPENSE_ACCOUNTS["General & Admin"])
    return {
        "Id": exp_id,
        "SyncToken": "0",
        "MetaData": {"CreateTime": qb_datetime(exp_date), "LastUpdatedTime": qb_datetime(exp_date)},
        "TxnDate": qb_date(exp_date),
        "PaymentType": "CreditCard",
        "AccountRef": {"value": account["qb_id"], "name": category},
        "EntityRef": {"value": str(random.randint(100, 999)), "name": vendor, "type": "Vendor"},
        "Line": [{
            "Id": "1", "Amount": amount, "DetailType": "AccountBasedExpenseLineDetail",
            "AccountBasedExpenseLineDetail": {
                "AccountRef": {"value": account["qb_id"], "name": category},
                "BillableStatus": "NotBillable", "ClassRef": None,
            },
            "Description": note or category,
        }],
        "TotalAmt": amount,
        "PrivateNote": note,
        "CurrencyRef": {"value": "USD"},
    }


def generate_monthly_expenses(year, month, ic_driver_count):
    """QUIRK 5: ~6% of fuel transactions miscoded as Vehicle Maintenance.
    QUIRK 4: COD remitted as a lump weekly deposit, not per-delivery.
    IC driver payment count is now sourced from shared_ids (how many IC
    drivers actually exist) rather than a hardcoded "13"."""
    month_start, month_end = month_range(year, month)
    expenses = []

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
        exp_date = month_start + timedelta(days=random.randint(1, 5))
        expenses.append(make_expense(exp_date, cat, amt, vendor, next_id(_exp_counter), note))

    for _ in range(random.randint(130, 155)):
        exp_date = month_start + timedelta(days=random.randint(0, 29))
        if random.random() < 0.06:
            category, note = "Vehicle Maintenance", "WEX Fleet Card — fuel (miscoded)"
        else:
            category, note = "Fuel", "WEX Fleet Card — fuel"
        fuel_amt = round(random.uniform(55, 145), 2)
        expenses.append(make_expense(exp_date, category, fuel_amt, "WEX Fleet Solutions", next_id(_exp_counter), note))

    for _ in range(random.randint(3, 8)):
        exp_date = month_start + timedelta(days=random.randint(0, 29))
        maint_amt = round(random.uniform(120, 1800), 2)
        expenses.append(make_expense(
            exp_date, "Vehicle Maintenance", maint_amt,
            random.choice(["Midas Auto Service","Jiffy Lube Commercial","Pep Boys Fleet","Denver Truck Center"]),
            next_id(_exp_counter),
            random.choice(["Oil change + tyre rotation","Brake service","Transmission service","Tyre replacement","Annual safety inspection"])))

    for week in range(4):
        for driver_n in range(ic_driver_count):
            exp_date = month_start + timedelta(days=week*7 + random.randint(0,2))
            ic_pay = round(random.uniform(280, 920), 2)
            expenses.append(make_expense(
                exp_date, "Driver Labour — IC", ic_pay, f"IC Driver #{str(driver_n+1).zfill(2)}",
                next_id(_exp_counter), f"Weekly IC driver payment — week {week+1}"))

    for week in range(4):
        exp_date = month_start + timedelta(days=week*7 + 4)
        cod_amt = round(random.uniform(1800, 4200), 2)
        expenses.append(make_expense(
            exp_date, "General & Admin", -cod_amt, "Internal — Driver COD Remittance",
            next_id(_exp_counter), f"COD cash remittance — week {week+1} (~{random.randint(60,120)} deliveries, lump total)"))

    for _ in range(random.randint(2, 5)):
        exp_date = month_start + timedelta(days=random.randint(0, 29))
        expenses.append(make_expense(
            exp_date, "Warehouse Supplies", round(random.uniform(80, 650), 2),
            random.choice(["Uline","Staples Business","Amazon Business"]),
            next_id(_exp_counter),
            random.choice(["Packing tape and boxes","Bubble wrap — bulk","Labels and barcode rolls","Pallet wrap"])))

    return expenses


# ══════════════════════════════════════════════════════════════════════════
#  QBO RESPONSE WRAPPER
# ══════════════════════════════════════════════════════════════════════════

def qbo_page(entity_name, records, start_pos, total_count):
    return {
        "QueryResponse": {
            entity_name: records,
            "startPosition": start_pos,
            "maxResults": len(records),
            "totalCount": total_count,
        },
        "time": qb_datetime(datetime.now(timezone.utc)),
    }


def write_pages(all_records, folder, entity_name, label):
    os.makedirs(folder, exist_ok=True)
    total = len(all_records)
    pages = [all_records[i:i+PAGE_SIZE] for i in range(0, len(all_records), PAGE_SIZE)]
    for idx, page in enumerate(pages, start=1):
        start_pos = (idx - 1) * PAGE_SIZE + 1
        payload = qbo_page(entity_name, page, start_pos, total)
        with open(os.path.join(folder, f"page_{str(idx).zfill(4)}.json"), "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2, ensure_ascii=False)
    return len(pages)


# ══════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════

def main():
    print("SwiftRoute — QuickBooks raw data generator")
    print("=" * 45)

    clients = build_qb_clients()
    net60 = [c for c in clients if c["is_net60"]]
    ic_driver_count = sum(1 for d in shared_ids.DRIVERS if d["employment_type"] == "IC")

    print(f"Clients    : {len(clients)} "
          f"({sum(1 for c in clients if c['tier']=='platinum')} platinum, "
          f"{sum(1 for c in clients if c['tier']=='gold')} gold, "
          f"{sum(1 for c in clients if c['tier']=='standard')} standard)")
    print(f"Net-60     : {len(net60)} clients  ← QUIRK 6 (from shared_ids)")
    print(f"IC drivers : {ic_driver_count}  (from shared_ids, for expense generation)")
    print()

    all_invoices = []
    all_payments = []
    all_expenses = []

    current = START_DATE
    while current <= END_DATE:
        year, month = current.year, current.month
        print(f"  Generating {year}-{str(month).zfill(2)}...")

        for client in clients:
            inv_id = next_id(_inv_counter)
            invoice = make_invoice(client, year, month, inv_id)
            all_invoices.append(invoice)

            pay_id = next_id(_pay_counter)
            payment = make_payment(client, invoice, pay_id)
            if payment:
                invoice["Balance"] = round(invoice["TotalAmt"] - payment["TotalAmt"], 2)
                invoice["LinkedTxn"].append({"TxnId": pay_id, "TxnType": "Payment"})
                all_payments.append(payment)

        month_expenses = generate_monthly_expenses(year, month, ic_driver_count)
        all_expenses.extend(month_expenses)

        if month == 12:
            current = datetime(year+1, 1, 1, tzinfo=timezone.utc)
        else:
            current = datetime(year, month+1, 1, tzinfo=timezone.utc)

    print()
    inv_pages = write_pages(all_invoices, os.path.join(OUTPUT_BASE, "invoices"), "Invoice", "invoices")
    pay_pages = write_pages(all_payments, os.path.join(OUTPUT_BASE, "payments"), "Payment", "payments")
    exp_pages = write_pages(all_expenses, os.path.join(OUTPUT_BASE, "expenses"), "Purchase", "expenses")

    unpaid = [i for i in all_invoices if i["Balance"] > 0]
    partial = [p for p in all_payments if p["UnappliedAmt"] > 0]
    miscoded = [e for e in all_expenses if "miscoded" in e.get("PrivateNote","")]
    cod = [e for e in all_expenses if "COD" in e.get("PrivateNote","")]

    print("=" * 45)
    print(f"Invoices   : {len(all_invoices):,}  ({inv_pages} pages)")
    print(f"Payments   : {len(all_payments):,}  ({pay_pages} pages)")
    print(f"Expenses   : {len(all_expenses):,}  ({exp_pages} pages)")
    print()
    print("Quirk verification:")
    print(f"  Unpaid / open invoices  : {len(unpaid):,}  ← QUIRK 3 (late / outstanding)")
    print(f"  Partial payments        : {len(partial):,}  ← QUIRK 2")
    print(f"  Fuel miscoded as Maint. : {len(miscoded):,}  ← QUIRK 5")
    print(f"  COD lump deposits       : {len(cod):,}  ← QUIRK 4")
    print(f"  Net-60 clients          : {len(net60):,}  ← QUIRK 6")
    print(f"\nOutput: {OUTPUT_BASE}")


if __name__ == "__main__":
    main()