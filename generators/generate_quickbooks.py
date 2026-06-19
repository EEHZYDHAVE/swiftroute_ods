"""
generators/generate_quickbooks.py

Generates synthetic QuickBooks Online API responses for SwiftRoute Logistics.
Mirrors the real QBO REST API JSON structure from three query endpoints:

  SELECT * FROM Invoice   → monthly client invoices
  SELECT * FROM Payment   → payments received against invoices
  SELECT * FROM Purchase  → operating expenses (fuel, maintenance, rent, etc.)

QuickBooks API characteristics (different from Onfleet and Linnworks):
  - Uses Intuit Query Language (IQL) — SQL-like syntax in the query param
  - Pagination uses startPosition + maxResults, not cursor or page number
  - Response always wrapped in {"QueryResponse": {...}, "time": "..."}
  - Dates are plain strings "YYYY-MM-DD", not ISO timestamps or milliseconds
  - Invoice line items show service type + quantity + rate — NO delivery IDs
    (this is the intentional gap that forces the join in the analytical layer)

Quirks intentionally reproduced:
  1. No delivery-level detail on invoices — forces cross-system join
  2. Partial payments — some clients consistently pay slightly short
  3. Late payments — some clients pay past the net-30 deadline
  4. COD appears as lump deposit, not per-delivery
  5. Expense miscategorisation — fuel sometimes coded as Vehicle Maintenance
  6. Two clients on net-60 terms instead of net-30

Output:
  data/raw/quickbooks/invoices/page_{NNNN}.json
  data/raw/quickbooks/payments/page_{NNNN}.json
  data/raw/quickbooks/expenses/page_{NNNN}.json

Period: 2025-01-01 to 2025-06-30
"""

import json
import os
import random
from datetime import datetime, timedelta, timezone, date as date_type
from faker import Faker

# ── Reproducibility ────────────────────────────────────────────────────────────
SEED = 42
random.seed(SEED)
fake = Faker()
Faker.seed(SEED)

# ── Paths ──────────────────────────────────────────────────────────────────────
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT_BASE  = os.path.join(PROJECT_ROOT, "data", "raw", "quickbooks")

# ── Simulation period ──────────────────────────────────────────────────────────
START_DATE = datetime(2025, 1,  1, tzinfo=timezone.utc)
END_DATE   = datetime(2025, 6, 30, tzinfo=timezone.utc)

# ── QBO pagination ─────────────────────────────────────────────────────────────
PAGE_SIZE = 100

# ── QBO company ID (would be in the real API URL) ─────────────────────────────
COMPANY_ID = "9341452837194821"

# ══════════════════════════════════════════════════════════════════════════════
#  CLIENT ROSTER
#  Mirrors the 94-account list from the operating document.
#  Each client has payment behaviour traits that create realistic AR patterns.
# ══════════════════════════════════════════════════════════════════════════════

def build_qb_clients():
    """
    94 clients as QuickBooks Customer records.
    Payment behaviour is assigned per client so the AR aging picture
    is consistent across invoices and payments for the same client.
    """
    random.seed(400)
    Faker.seed(400)

    clients = []
    qb_id   = 1

    tier_specs = [
        # (tier, count, payment_term_days, late_pct, partial_pct, channel_mix)
        ("platinum", 9,  30, 0.05, 0.03,
         ["ACH","ACH","ACH","CREDIT_CARD"]),
        ("gold",     28, 30, 0.15, 0.08,
         ["ACH","ACH","CREDIT_CARD","CHECK"]),
        ("standard", 57, 30, 0.28, 0.14,
         ["ACH","CREDIT_CARD","CHECK","CHECK"]),
    ]

    # Two clients get net-60 terms (quirk 6)
    net60_slots = random.sample(range(9, 37), 2)

    idx = 0
    for tier, count, terms, late_pct, partial_pct, channels in tier_specs:
        for i in range(count):
            is_net60 = idx in net60_slots
            clients.append({
                "qb_id":        str(qb_id),
                "internal_id":  f"client_{str(idx+1).zfill(3)}",
                "name":         fake.company(),
                "tier":         tier,
                "terms_days":   60 if is_net60 else terms,
                "late_pct":     late_pct,
                "partial_pct":  partial_pct,
                "pay_channel":  random.choice(channels),
                "email":        fake.company_email(),
                "is_net60":     is_net60,
            })
            qb_id += 1
            idx   += 1

    random.seed(SEED)
    Faker.seed(SEED)
    return clients


# ══════════════════════════════════════════════════════════════════════════════
#  SERVICE ITEMS  (QuickBooks Items used on invoice lines)
# ══════════════════════════════════════════════════════════════════════════════

SERVICE_ITEMS = {
    "same_day":          {"qb_item_id": "1", "name": "Same-Day Delivery",
                          "unit_price_range": (8.50, 32.00)},
    "next_day":          {"qb_item_id": "2", "name": "Next-Day Delivery",
                          "unit_price_range": (6.50, 24.00)},
    "scheduled":         {"qb_item_id": "3", "name": "Scheduled Window Delivery",
                          "unit_price_range": (12.00, 28.00)},
    "fulfillment_pick":  {"qb_item_id": "4", "name": "Fulfillment — Pick & Pack",
                          "unit_price_range": (1.80, 4.50)},
    "storage":           {"qb_item_id": "5", "name": "Warehouse Storage",
                          "unit_price_range": (28.00, 95.00)},
    "returns":           {"qb_item_id": "6", "name": "Returns Handling",
                          "unit_price_range": (5.00, 18.00)},
    "distribution_run":  {"qb_item_id": "7", "name": "B2B Distribution Run",
                          "unit_price_range": (85.00, 280.00)},
}

# ── Volume estimates by tier (deliveries per month) ────────────────────────────
MONTHLY_VOLUME = {
    "platinum": (800,  1800),
    "gold":     (200,  800),
    "standard": (30,   200),
}

# ── Expense categories ─────────────────────────────────────────────────────────
EXPENSE_ACCOUNTS = {
    "Fuel":                 {"qb_id": "101", "type": "Expense"},
    "Vehicle Maintenance":  {"qb_id": "102", "type": "Expense"},
    "Vehicle Leasing":      {"qb_id": "103", "type": "Expense"},
    "Driver Labour — IC":   {"qb_id": "104", "type": "Expense"},
    "Warehouse Rent":       {"qb_id": "105", "type": "Expense"},
    "Warehouse Supplies":   {"qb_id": "106", "type": "Expense"},
    "Insurance":            {"qb_id": "107", "type": "Expense"},
    "Software & Technology":{"qb_id": "108", "type": "Expense"},
    "General & Admin":      {"qb_id": "109", "type": "Expense"},
}

# ══════════════════════════════════════════════════════════════════════════════
#  HELPER FUNCTIONS
# ══════════════════════════════════════════════════════════════════════════════

_inv_counter  = [1000]
_pay_counter  = [5000]
_exp_counter  = [9000]

def next_id(counter):
    counter[0] += 1
    return str(counter[0])

def qb_date(dt):
    """QuickBooks uses plain date strings, not timestamps."""
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


# ══════════════════════════════════════════════════════════════════════════════
#  INVOICE GENERATOR
# ══════════════════════════════════════════════════════════════════════════════

def make_invoice(client, year, month, inv_id):
    """
    One QuickBooks invoice = one monthly bill for a client.

    QUIRK 1: Line items show service type, quantity, and unit rate —
    but NO delivery IDs. To know which specific deliveries are on this
    invoice you must join to Onfleet using client_id + billing period.
    This is the intentional cross-system gap in SwiftRoute's data.
    """
    month_start, month_end = month_range(year, month)

    # Invoice date = first business day of the following month
    invoice_date = month_end + timedelta(days=1)
    while invoice_date.weekday() > 4:   # skip weekend
        invoice_date += timedelta(days=1)

    due_date = invoice_date + timedelta(days=client["terms_days"])

    # Estimate delivery volumes this month
    lo, hi  = MONTHLY_VOLUME[client["tier"]]
    total_vol = random.randint(lo, hi)

    # Split volume across service types
    lines  = []
    line_n = 1
    total  = 0.0

    # Determine which service types this client uses
    use_types = ["next_day"]
    if client["tier"] in ("platinum", "gold") and random.random() > 0.3:
        use_types.append("same_day")
    if random.random() > 0.7:
        use_types.append("returns")
    if client["tier"] == "platinum" and random.random() > 0.5:
        use_types.append("distribution_run")

    # Internal client IDs 001-011 are fulfillment clients
    client_num = int(client["internal_id"].split("_")[1])
    is_ff = client_num <= 11

    if is_ff:
        use_types = ["fulfillment_pick", "storage"]
        if random.random() > 0.6:
            use_types.append("returns")

    remaining_vol = total_vol
    for i, svc in enumerate(use_types):
        item = SERVICE_ITEMS[svc]
        lo_r, hi_r = item["unit_price_range"]
        unit_price  = round(random.uniform(lo_r, hi_r), 2)

        if i == len(use_types) - 1:
            qty = remaining_vol
        else:
            qty = max(1, int(remaining_vol * random.uniform(0.2, 0.6)))
            remaining_vol -= qty

        amount = round(qty * unit_price, 2)
        total += amount

        lines.append({
            "Id":          str(line_n),
            "LineNum":     line_n,
            # QUIRK 1: description shows period and service type but NO delivery IDs
            "Description": (f"{item['name']} — "
                            f"{month_start.strftime('%B %Y')} "
                            f"({qty} units)"),
            "Amount":      amount,
            "DetailType":  "SalesItemLineDetail",
            "SalesItemLineDetail": {
                "ItemRef":   {
                    "value": item["qb_item_id"],
                    "name":  item["name"],
                },
                "UnitPrice": unit_price,
                "Qty":       qty,
                "ServiceDate": qb_date(month_end),
                # No delivery IDs — this is the gap
            },
        })
        line_n += 1

    total = round(total, 2)

    return {
        "Id":        inv_id,
        "SyncToken": str(random.randint(0, 5)),
        "MetaData": {
            "CreateTime":      qb_datetime(invoice_date),
            "LastUpdatedTime": qb_datetime(invoice_date + timedelta(hours=2)),
        },
        "DocNumber":   f"INV-{year}-{inv_id.zfill(5)}",
        "TxnDate":     qb_date(invoice_date),
        "DueDate":     qb_date(due_date),
        "CustomerRef": {
            "value": client["qb_id"],
            "name":  client["name"],
        },
        "BillEmail":   {"Address": client["email"]},
        "EmailStatus": "EmailSent",
        "Line":        lines,
        "TotalAmt":    total,
        "Balance":     total,     # will be updated when payment is applied
        "CurrencyRef": {"value": "USD", "name": "United States Dollar"},
        "PaymentMethodRef": {
            "value": "1",
            "name":  client["pay_channel"],
        },
        "LinkedTxn":   [],        # populated when payment is recorded
        # SwiftRoute custom fields (added via QBO custom fields feature)
        "CustomField": [
            {"DefinitionId": "1", "Name": "SwiftRoute Client ID",
             "Type": "StringType", "StringValue": client["internal_id"]},
            {"DefinitionId": "2", "Name": "Billing Period",
             "Type": "StringType",
             "StringValue": f"{year}-{str(month).zfill(2)}"},
            {"DefinitionId": "3", "Name": "Payment Terms",
             "Type": "StringType",
             "StringValue": f"Net {client['terms_days']}"},
        ],
    }


# ══════════════════════════════════════════════════════════════════════════════
#  PAYMENT GENERATOR
# ══════════════════════════════════════════════════════════════════════════════

def make_payment(client, invoice, pay_id):
    """
    QUIRK 2: Partial payments — some clients pay slightly short.
    QUIRK 3: Late payments — some clients pay after the due date.
    QUIRK 6: Net-60 clients show in AR aging as 60-day terms.
    """
    inv_total  = invoice["TotalAmt"]
    due_date   = datetime.strptime(invoice["DueDate"], "%Y-%m-%d")
    inv_date   = datetime.strptime(invoice["TxnDate"],  "%Y-%m-%d")

    # Decide if this invoice gets paid at all this period
    if random.random() < 0.04:
        return None     # ~4% unpaid within the simulation window

    # Payment timing
    if random.random() < client["late_pct"]:
        # Late payment: 5–35 days after due date
        pay_date = due_date + timedelta(days=random.randint(5, 35))
    else:
        # On time: 0–5 days before due date
        pay_date = due_date - timedelta(days=random.randint(0, 5))

    # Clamp to end of simulation
    if pay_date.replace(tzinfo=timezone.utc) > END_DATE:
        return None     # payment falls outside our period — leaves balance open

    # Partial payment quirk
    if random.random() < client["partial_pct"]:
        # Client pays 93–99% of invoice — dispute or rounding
        pay_amount = round(inv_total * random.uniform(0.93, 0.99), 2)
    else:
        pay_amount = inv_total

    unapplied = round(inv_total - pay_amount, 2)

    return {
        "Id":        pay_id,
        "SyncToken": "0",
        "MetaData": {
            "CreateTime":      qb_datetime(pay_date),
            "LastUpdatedTime": qb_datetime(pay_date),
        },
        "TxnDate":     qb_date(pay_date),
        "CustomerRef": {
            "value": client["qb_id"],
            "name":  client["name"],
        },
        "TotalAmt":  pay_amount,
        "UnappliedAmt": unapplied,
        "ProcessPayment": False,
        "PaymentMethodRef": {
            "value": "1",
            "name":  client["pay_channel"],
        },
        "DepositToAccountRef": {
            "value": "35",
            "name":  "Checking — GTBank Business",
        },
        "Line": [{
            "Amount":         pay_amount,
            "LinkedTxn": [{
                "TxnId":   invoice["Id"],
                "TxnType": "Invoice",
            }],
        }],
        # SwiftRoute custom
        "CustomField": [
            {"DefinitionId": "1", "Name": "SwiftRoute Client ID",
             "Type": "StringType", "StringValue": client["internal_id"]},
            {"DefinitionId": "4", "Name": "Days to Pay",
             "Type": "StringType",
             "StringValue": str((pay_date - inv_date).days)},
        ],
    }


# ══════════════════════════════════════════════════════════════════════════════
#  EXPENSE GENERATOR
# ══════════════════════════════════════════════════════════════════════════════

def make_expense(exp_date, category, amount, vendor, exp_id, note=""):
    """
    QUIRK 4: COD deposits appear as a lump sum Purchase record tagged
    'COD Remittance', not as individual delivery payments.

    QUIRK 5: Expense miscategorisation — some fuel transactions are
    coded under 'Vehicle Maintenance' instead of 'Fuel'.
    """
    account = EXPENSE_ACCOUNTS.get(category, EXPENSE_ACCOUNTS["General & Admin"])

    return {
        "Id":        exp_id,
        "SyncToken": "0",
        "MetaData": {
            "CreateTime":      qb_datetime(exp_date),
            "LastUpdatedTime": qb_datetime(exp_date),
        },
        "TxnDate":    qb_date(exp_date),
        "PaymentType": "CreditCard",
        "AccountRef": {
            "value": account["qb_id"],
            "name":  category,
        },
        "EntityRef": {
            "value": str(random.randint(100, 999)),
            "name":  vendor,
            "type":  "Vendor",
        },
        "Line": [{
            "Id":     "1",
            "Amount": amount,
            "DetailType": "AccountBasedExpenseLineDetail",
            "AccountBasedExpenseLineDetail": {
                "AccountRef": {
                    "value": account["qb_id"],
                    "name":  category,
                },
                "BillableStatus": "NotBillable",
                "ClassRef": None,
            },
            "Description": note or category,
        }],
        "TotalAmt": amount,
        "PrivateNote": note,
        "CurrencyRef": {"value": "USD"},
    }


def generate_monthly_expenses(year, month):
    """
    Generate realistic operating expenses for one month.
    Fixed costs appear every month. Variable costs fluctuate.
    """
    month_start, month_end = month_range(year, month)
    expenses = []

    # ── Fixed monthly costs ────────────────────────────────────────────────────
    fixed = [
        ("Warehouse Rent",      18500.00, "Denver Industrial Properties LLC",
         "Monthly warehouse rent — Denver WH"),
        ("Insurance",            3200.00, "Gallagher Commercial Insurance",
         "Fleet and liability insurance premium"),
        ("Vehicle Leasing",      8400.00, "Enterprise Fleet Management",
         "Monthly vehicle lease — 22 cargo vans + 4 box trucks"),
        ("Software & Technology", 890.00, "Onfleet Inc.",
         "TMS subscription — 48 driver seats"),
        ("Software & Technology", 420.00, "Samsara Inc.",
         "Fleet telematics — 36 vehicles"),
        ("Software & Technology", 310.00, "Zendesk Inc.",
         "Customer support platform"),
        ("Software & Technology", 175.00, "Linnworks Ltd.",
         "WMS subscription"),
        ("Software & Technology",  85.00, "Supabase Inc.",
         "Database hosting"),
    ]

    for i, (cat, amt, vendor, note) in enumerate(fixed):
        exp_date = month_start + timedelta(days=random.randint(1, 5))
        expenses.append(make_expense(
            exp_date, cat, amt, vendor, next_id(_exp_counter), note))

    # ── Fuel — weekly WEX card transactions ───────────────────────────────────
    # 36 vehicles, ~4 fill-ups per vehicle per month = ~144 fuel transactions
    for _ in range(random.randint(130, 155)):
        exp_date = month_start + timedelta(days=random.randint(0, 29))

        # QUIRK 5: ~6% of fuel transactions are miscoded as Vehicle Maintenance
        if random.random() < 0.06:
            category = "Vehicle Maintenance"
            note     = "WEX Fleet Card — fuel (miscoded)"
        else:
            category = "Fuel"
            note     = "WEX Fleet Card — fuel"

        fuel_amt = round(random.uniform(55, 145), 2)
        expenses.append(make_expense(
            exp_date, category, fuel_amt, "WEX Fleet Solutions",
            next_id(_exp_counter), note))

    # ── Vehicle maintenance ────────────────────────────────────────────────────
    for _ in range(random.randint(3, 8)):
        exp_date = month_start + timedelta(days=random.randint(0, 29))
        maint_amt = round(random.uniform(120, 1800), 2)
        expenses.append(make_expense(
            exp_date, "Vehicle Maintenance", maint_amt,
            random.choice(["Midas Auto Service","Jiffy Lube Commercial",
                           "Pep Boys Fleet","Denver Truck Center"]),
            next_id(_exp_counter),
            random.choice(["Oil change + tyre rotation","Brake service",
                           "Transmission service","Tyre replacement",
                           "Annual safety inspection"])))

    # ── IC driver payments ─────────────────────────────────────────────────────
    # 13 IC drivers, paid weekly — appears as lump vendor payment per driver
    for week in range(4):
        for driver_n in range(13):
            exp_date  = month_start + timedelta(days=week*7 + random.randint(0,2))
            ic_pay    = round(random.uniform(280, 920), 2)
            expenses.append(make_expense(
                exp_date, "Driver Labour — IC", ic_pay,
                f"IC Driver #{str(driver_n+1).zfill(2)}",
                next_id(_exp_counter),
                f"Weekly IC driver payment — week {week+1}"))

    # ── COD lump deposits (QUIRK 4) ────────────────────────────────────────────
    # Drivers remit cash weekly. Appears as a single deposit, not per delivery.
    for week in range(4):
        exp_date = month_start + timedelta(days=week*7 + 4)  # Friday
        cod_amt  = round(random.uniform(1800, 4200), 2)
        # Note: this is a NEGATIVE expense (money received)
        # In QBO it appears as a bank deposit, logged here for completeness
        expenses.append(make_expense(
            exp_date, "General & Admin", -cod_amt,
            "Internal — Driver COD Remittance",
            next_id(_exp_counter),
            f"COD cash remittance — week {week+1} "
            f"(~{random.randint(60,120)} deliveries, lump total)"))

    # ── Warehouse supplies ─────────────────────────────────────────────────────
    for _ in range(random.randint(2, 5)):
        exp_date = month_start + timedelta(days=random.randint(0, 29))
        expenses.append(make_expense(
            exp_date, "Warehouse Supplies",
            round(random.uniform(80, 650), 2),
            random.choice(["Uline","Staples Business","Amazon Business"]),
            next_id(_exp_counter),
            random.choice(["Packing tape and boxes","Bubble wrap — bulk",
                           "Labels and barcode rolls","Pallet wrap"])))

    return expenses


# ══════════════════════════════════════════════════════════════════════════════
#  QBO RESPONSE WRAPPER
#  Real QBO API wraps every response in {"QueryResponse": {...}, "time": "..."}
# ══════════════════════════════════════════════════════════════════════════════

def qbo_page(entity_name, records, start_pos, total_count):
    """Wrap records in the real QBO API response envelope."""
    return {
        "QueryResponse": {
            entity_name:    records,
            "startPosition": start_pos,
            "maxResults":    len(records),
            "totalCount":    total_count,
        },
        "time": qb_datetime(datetime.now(timezone.utc)),
    }


def write_pages(all_records, folder, entity_name, label):
    os.makedirs(folder, exist_ok=True)
    total  = len(all_records)
    pages  = [all_records[i:i+PAGE_SIZE]
              for i in range(0, len(all_records), PAGE_SIZE)]

    for idx, page in enumerate(pages, start=1):
        start_pos = (idx - 1) * PAGE_SIZE + 1
        payload   = qbo_page(entity_name, page, start_pos, total)
        path      = os.path.join(folder, f"page_{str(idx).zfill(4)}.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2, ensure_ascii=False)

    return len(pages)


# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════

def main():
    print("SwiftRoute — QuickBooks raw data generator")
    print("=" * 45)

    clients = build_qb_clients()
    net60   = [c for c in clients if c["is_net60"]]
    print(f"Clients    : {len(clients)} "
          f"({sum(1 for c in clients if c['tier']=='platinum')} platinum, "
          f"{sum(1 for c in clients if c['tier']=='gold')} gold, "
          f"{sum(1 for c in clients if c['tier']=='standard')} standard)")
    print(f"Net-60     : {len(net60)} clients  ← QUIRK 6")
    print()

    all_invoices = []
    all_payments = []
    all_expenses = []

    current = START_DATE
    while current <= END_DATE:
        year  = current.year
        month = current.month

        print(f"  Generating {year}-{str(month).zfill(2)}...")

        # ── Invoices ────────────────────────────────────────────────────────
        for client in clients:
            inv_id  = next_id(_inv_counter)
            invoice = make_invoice(client, year, month, inv_id)
            all_invoices.append(invoice)

            # ── Payment for this invoice ─────────────────────────────────
            pay_id  = next_id(_pay_counter)
            payment = make_payment(client, invoice, pay_id)
            if payment:
                # Update invoice balance
                invoice["Balance"] = round(
                    invoice["TotalAmt"] - payment["TotalAmt"], 2)
                invoice["LinkedTxn"].append({
                    "TxnId":   pay_id,
                    "TxnType": "Payment",
                })
                all_payments.append(payment)

        # ── Expenses ────────────────────────────────────────────────────────
        month_expenses = generate_monthly_expenses(year, month)
        all_expenses.extend(month_expenses)

        # Advance to next month
        if month == 12:
            current = datetime(year+1, 1, 1, tzinfo=timezone.utc)
        else:
            current = datetime(year, month+1, 1, tzinfo=timezone.utc)

    # ── Write all records ──────────────────────────────────────────────────────
    print()
    inv_pages = write_pages(
        all_invoices, os.path.join(OUTPUT_BASE, "invoices"),
        "Invoice", "invoices")
    pay_pages = write_pages(
        all_payments, os.path.join(OUTPUT_BASE, "payments"),
        "Payment", "payments")
    exp_pages = write_pages(
        all_expenses, os.path.join(OUTPUT_BASE, "expenses"),
        "Purchase", "expenses")

    # ── Summary ────────────────────────────────────────────────────────────────
    unpaid = [i for i in all_invoices if i["Balance"] > 0]
    partial = [p for p in all_payments if p["UnappliedAmt"] > 0]
    miscoded = [e for e in all_expenses
                if "miscoded" in e.get("PrivateNote","")]
    cod = [e for e in all_expenses
           if "COD" in e.get("PrivateNote","")]

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
    print()
    print("Key things to notice when you open these files:")
    print("  1. Invoice lines have no Onfleet delivery IDs — join must be built")
    print("  2. Dates are plain strings '2025-02-05', not timestamps")
    print("  3. Response wrapped in QueryResponse envelope (QBO API standard)")
    print("  4. Pagination uses startPosition/maxResults, not cursor or page number")
    print("  5. COD remittances are negative expense entries, not payment records")
    print(f"\nOutput: {OUTPUT_BASE}")


if __name__ == "__main__":
    main()
