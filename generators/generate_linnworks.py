"""
generators/generate_linnworks.py

Generates synthetic Linnworks API responses for SwiftRoute Logistics.
Mirrors the real Linnworks JSON structure from three endpoints:

  1. /api/ProcessedOrders/Search  → fulfilled e-commerce orders
  2. /api/Stock/GetStockItemsFull → product catalogue (all SKUs per client)
  3. /api/Stock/GetStockTransactions → every inventory movement

Quirks intentionally reproduced:
  - SKU inconsistency: same product entered under slightly different codes
  - Negative stock levels: dispatch recorded before receipt is processed
  - Orphaned transactions: reference an order that no longer exists
  - Linnworks page-number pagination (not cursor-based like Onfleet)

Output:
  data/raw/linnworks/processed_orders/{YYYY_MM}/page_{NNNN}.json
  data/raw/linnworks/stock_items/stock_items.json
  data/raw/linnworks/stock_transactions/{YYYY_MM}/page_{NNNN}.json

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
OUTPUT_BASE  = os.path.join(PROJECT_ROOT, "data", "raw", "linnworks")

# ── Simulation period ──────────────────────────────────────────────────────────
START_DATE = datetime(2025, 1,  1, tzinfo=timezone.utc)
END_DATE   = datetime(2025, 6, 30, tzinfo=timezone.utc)

# ── Page size (Linnworks default) ──────────────────────────────────────────────
PAGE_SIZE = 100

# ── Fulfillment clients (11 total, matching Onfleet reference data) ────────────
# Each client has a set of SKUs and a daily order volume range
FULFILLMENT_CLIENTS = [
    # Platinum fulfillment clients (3)
    {"id":"client_001","name":"Apex Athletic Co.",      "tier":"platinum",
     "sku_prefix":"APEX",  "sku_count":28, "daily_orders":(18, 32)},
    {"id":"client_002","name":"NordicHome Essentials",  "tier":"platinum",
     "sku_prefix":"NRDC",  "sku_count":41, "daily_orders":(12, 22)},
    {"id":"client_003","name":"UrbanGlow Skincare",     "tier":"platinum",
     "sku_prefix":"UGLW",  "sku_count":19, "daily_orders":(22, 40)},
    # Gold fulfillment clients (5)
    {"id":"client_010","name":"Rocky Mountain Brew",    "tier":"gold",
     "sku_prefix":"RMBR",  "sku_count":14, "daily_orders":(8, 16)},
    {"id":"client_011","name":"Summit Pet Supplies",    "tier":"gold",
     "sku_prefix":"SMPT",  "sku_count":22, "daily_orders":(10, 20)},
    {"id":"client_012","name":"Elevated Outdoor Gear",  "tier":"gold",
     "sku_prefix":"ELVT",  "sku_count":33, "daily_orders":(6, 14)},
    {"id":"client_013","name":"PureLeaf Nutrition",     "tier":"gold",
     "sku_prefix":"PLNT",  "sku_count":17, "daily_orders":(14, 26)},
    {"id":"client_014","name":"Craftwork Candles",      "tier":"gold",
     "sku_prefix":"CRFT",  "sku_count":11, "daily_orders":(5, 12)},
    # Standard fulfillment clients (3)
    {"id":"client_040","name":"Mile High Apparel",      "tier":"standard",
     "sku_prefix":"MLHI",  "sku_count":16, "daily_orders":(4, 10)},
    {"id":"client_041","name":"Desert Sun Gifts",       "tier":"standard",
     "sku_prefix":"DSRT",  "sku_count":9,  "daily_orders":(3, 8)},
    {"id":"client_042","name":"Cascade Home Decor",     "tier":"standard",
     "sku_prefix":"CSCD",  "sku_count":12, "daily_orders":(4, 9)},
]

# ── Product categories and attributes ─────────────────────────────────────────
CATEGORIES = ["Apparel","Footwear","Skincare","Nutrition","Home & Garden",
               "Pet Supplies","Outdoor Gear","Food & Beverage","Gifts","Candles"]

CHANNELS   = ["SHOPIFY","WOOCOMMERCE","AMAZON","DIRECT","ETSY"]

# ══════════════════════════════════════════════════════════════════════════════
#  HELPER FUNCTIONS
# ══════════════════════════════════════════════════════════════════════════════

def lw_guid():
    """Linnworks uses standard GUIDs (UUID4 format)."""
    h = lambda n: "".join(random.choices(string.hexdigits[:16], k=n))
    return f"{h(8)}-{h(4)}-{h(4)}-{h(4)}-{h(12)}".upper()

def lw_order_id():
    return f"ORD-{random.randint(100000, 999999)}"

def lw_ref():
    return f"LW{random.randint(10000000, 99999999)}"

def ms(dt):
    return int(dt.timestamp() * 1000)

def iso(dt):
    """Linnworks returns ISO 8601 strings, NOT millisecond timestamps."""
    return dt.strftime("%Y-%m-%dT%H:%M:%S.000Z")

def seasonal_mult(date):
    m = date.month
    if m == 1: return 0.85
    if m == 2: return 0.88
    if m in (3, 4): return 1.00
    if m == 5:
        md = datetime(2025, 5, 11, tzinfo=timezone.utc)
        if md - timedelta(days=6) <= date <= md + timedelta(days=1):
            return 1.20
        return 1.05
    if m == 6: return 0.95
    return 1.00

DOW_MULT = {0:1.00,1:1.05,2:1.05,3:1.00,4:0.95,5:0.70,6:0.25}

# ══════════════════════════════════════════════════════════════════════════════
#  STOCK ITEMS — product catalogue
# ══════════════════════════════════════════════════════════════════════════════

def build_stock_items():
    """
    Build the full SKU catalogue for all 11 fulfillment clients.

    QUIRK: SKU inconsistency — for ~8% of items, a duplicate entry exists
    with a slightly different SKU format (underscore vs hyphen, or lowercase).
    In a real warehouse this happens when different staff members enter the
    same product at different times without checking for duplicates.
    """
    random.seed(300)
    Faker.seed(300)

    items      = []
    sku_registry = {}   # sku → item_guid, used later for transactions

    for client in FULFILLMENT_CLIENTS:
        prefix = client["sku_prefix"]
        for i in range(client["sku_count"]):
            item_id  = lw_guid()
            # Standard SKU format: PREFIX-CAT-NNN
            sku_clean = f"{prefix}-{random.choice(['A','B','C','D','E'])}{str(i+1).zfill(3)}"

            # QUIRK: ~8% get a duplicate entry with a malformed SKU
            introduce_dup = random.random() < 0.08
            sku_used = sku_clean

            weight_g  = random.randint(50, 5000)
            dims_cm   = {
                "Width":  round(random.uniform(3, 40), 1),
                "Height": round(random.uniform(2, 30), 1),
                "Depth":  round(random.uniform(2, 35), 1),
            }
            cost_price = round(random.uniform(2.50, 85.00), 2)
            retail     = round(cost_price * random.uniform(1.8, 4.5), 2)
            qty_on_hand = random.randint(0, 400)

            item = {
                # Linnworks stock item fields
                "StockItemId":       item_id,
                "ItemNumber":        sku_used,          # this is the SKU
                "ItemTitle":         fake.catch_phrase(),
                "BarcodeNumber":     f"{random.randint(1000000000000, 9999999999999)}",
                "CategoryName":      random.choice(CATEGORIES),
                "PackageGroupName":  "Standard",
                "TaxCostInclusive":  False,
                "PostalServiceName": "SwiftRoute Standard",
                "CostPrice":         cost_price,
                "RetailPrice":       retail,
                "Weight":            weight_g,
                "Width":             dims_cm["Width"],
                "Height":            dims_cm["Height"],
                "Depth":             dims_cm["Depth"],
                "IsCompositeParent": False,
                "IsVariationParent": random.random() < 0.15,
                "Quantity":          qty_on_hand,        # CURRENT quantity only
                "MinimumLevel":      random.randint(5, 30),
                "InOrderBook":       random.randint(0, 20),
                "Due":               random.randint(0, 50),
                "JIT":               False,
                "CreationDate":      iso(START_DATE - timedelta(days=random.randint(30, 365))),
                "ModifiedDate":      iso(START_DATE - timedelta(days=random.randint(0, 30))),
                "Source":            "DIRECT",
                "IsDeleted":         False,
                # SwiftRoute custom fields
                "_swiftroute_client_id":   client["id"],
                "_swiftroute_client_name": client["name"],
            }
            items.append(item)
            sku_registry[sku_used] = item_id

            # Add the duplicate with a corrupted SKU
            if introduce_dup:
                bad_sku = sku_clean.replace("-", "_").lower()   # PREFIX_catNNN
                dup_item = dict(item)
                dup_item["StockItemId"] = lw_guid()             # different GUID
                dup_item["ItemNumber"]  = bad_sku               # different SKU format
                dup_item["Quantity"]    = random.randint(0, 50) # different count
                dup_item["CreationDate"] = iso(
                    START_DATE - timedelta(days=random.randint(1, 20)))
                items.append(dup_item)
                sku_registry[bad_sku] = dup_item["StockItemId"]

    random.seed(SEED)
    Faker.seed(SEED)
    return items, sku_registry


# ══════════════════════════════════════════════════════════════════════════════
#  PROCESSED ORDERS — fulfilled e-commerce orders
# ══════════════════════════════════════════════════════════════════════════════

def make_processed_order(date, client, stock_items_for_client):
    """
    One Linnworks processed order = one consumer order that was picked,
    packed, and dispatched from the SwiftRoute warehouse.

    The 'ReferenceNum' field is what links this record back to an
    Onfleet task. In real life this mapping is maintained by the
    middleware script that pushes packed orders into Onfleet.
    """
    order_id   = lw_guid()
    processed_at = date.replace(
        hour=random.randint(6, 17),
        minute=random.randint(0, 59),
        second=random.randint(0, 59),
        microsecond=0,
    )
    dispatched_at = processed_at + timedelta(minutes=random.randint(15, 120))

    # 1–4 line items per order
    num_lines  = random.choices([1,2,3,4], weights=[0.50,0.30,0.15,0.05])[0]
    items_pool = stock_items_for_client
    chosen     = random.sample(items_pool, min(num_lines, len(items_pool)))

    order_items = []
    subtotal    = 0.0
    for itm in chosen:
        qty       = random.randint(1, 3)
        unit_price= itm["RetailPrice"]
        line_total= round(qty * unit_price, 2)
        subtotal += line_total
        order_items.append({
            "StockItemId":    itm["StockItemId"],
            "SKU":            itm["ItemNumber"],
            "ItemTitle":      itm["ItemTitle"],
            "Quantity":       qty,
            "UnitCost":       itm["CostPrice"],
            "PricePerUnit":   unit_price,
            "LineTotal":      line_total,
            "Weight":         itm["Weight"] * qty,
            "IsComposite":    False,
            "BinRack":        f"BIN-{random.randint(1,50):02d}-{random.randint(1,20):02d}",
        })

    shipping_cost = round(random.uniform(0, 12), 2)
    total_cost    = round(subtotal + shipping_cost, 2)

    channel = random.choice(CHANNELS)

    return {
        # Core Linnworks processed order fields
        "pkOrderID":           order_id,
        "NumOrderId":          random.randint(10000, 999999),
        "ReferenceNum":        lw_ref(),       # links to Onfleet via middleware
        "ExternalReference":   f"{channel}-{random.randint(100000,999999)}",
        "SecondaryReference":  "",
        "Channel":             channel,
        "Source":              channel,
        "SubSource":           client["name"],
        "SiteCode":            "DENVER-WH",
        "FulfilmentLocationName": "Denver Warehouse",

        # Dates — Linnworks uses ISO strings, not milliseconds
        "ReceivedDate":        iso(processed_at - timedelta(minutes=random.randint(5, 60))),
        "ProcessedOn":         iso(processed_at),
        "DispatchedOn":        iso(dispatched_at),

        # Customer (end consumer, not the fulfillment client)
        "CustomerName":        fake.name(),
        "CustomerEmail":       fake.email(),
        "Address": {
            "FullName":    fake.name(),
            "Company":     "",
            "Address1":    fake.street_address(),
            "Address2":    "",
            "City":        fake.city(),
            "Region":      fake.state(),
            "PostCode":    fake.postcode(),
            "Country":     "United States",
            "CountryCode": "US",
            "Phone":       fake.phone_number(),
        },

        # Financials
        "SubTotal":            round(subtotal, 2),
        "PostalServiceCost":   shipping_cost,
        "TotalCharge":         total_cost,
        "TaxAmount":           round(total_cost * 0.08, 2),
        "Currency":            "USD",
        "PaymentMethod":       random.choice(["SHOPIFY_PAYMENTS","PAYPAL",
                                               "STRIPE","AMAZON_PAY"]),
        "PaymentStatus":       "PAID",

        # Status
        "GeneralInfo": {
            "Status":         3,          # 3 = Dispatched in Linnworks
            "LockForShipping": False,
            "Marker":         0,
            "Notes":          random.choice(["","","Gift — no invoice","Fragile items"]),
        },

        # Shipping
        "ShippingInfo": {
            "PostalServiceName": "SwiftRoute Same Day" if random.random() < 0.35
                                  else "SwiftRoute Next Day",
            "TrackingNumber":    f"SR{random.randint(1000000000, 9999999999)}",
            "Vendor":            "SwiftRoute Logistics",
            "PostalServiceCode": "SR-SD" if random.random() < 0.35 else "SR-ND",
        },

        # Line items
        "Items": order_items,

        # SwiftRoute custom fields
        "_swiftroute_client_id":   client["id"],
        "_swiftroute_client_name": client["name"],
        "_swiftroute_pick_duration_mins": random.randint(3, 18),
    }


# ══════════════════════════════════════════════════════════════════════════════
#  STOCK TRANSACTIONS — every inventory movement
# ══════════════════════════════════════════════════════════════════════════════

TRANSACTION_TYPES = {
    "DISPATCH":     "Stock removed for a processed order",
    "RECEIPT":      "Stock received from supplier",
    "ADJUSTMENT":   "Manual stock count correction",
    "RETURN":       "Customer return restocked",
    "TRANSFER":     "Stock moved between bin locations",
    "WRITE_OFF":    "Damaged or expired stock removed",
}

def make_transaction(date, stock_item, tx_type, qty_change,
                     order_ref=None, is_orphan=False):
    """
    One stock transaction = one inventory movement event.

    QUIRK: orphaned transactions have an order reference that does not
    exist in the processed orders list. This happens when an order is
    manually deleted from Linnworks after the stock was already moved.

    QUIRK: negative stock — if a DISPATCH is recorded before the
    RECEIPT that would have replenished the stock, the running total
    goes negative. This is valid data in Linnworks.
    """
    occurred = date.replace(
        hour=random.randint(6, 20),
        minute=random.randint(0, 59),
        second=random.randint(0, 59),
        microsecond=0,
    )

    ref = order_ref
    if is_orphan:
        # Reference an order ID that was deleted — will cause join failure
        ref = f"DELETED-ORD-{random.randint(10000,99999)}"

    return {
        "pkStockTransactionId": lw_guid(),
        "fkStockItemId":        stock_item["StockItemId"],
        "SKU":                  stock_item["ItemNumber"],
        "ItemTitle":            stock_item["ItemTitle"],
        "TransactionType":      tx_type,
        "TransactionNote":      TRANSACTION_TYPES[tx_type],
        "Quantity":             qty_change,      # negative = stock out
        "fkOrderId":            ref,             # null unless DISPATCH or RETURN
        "Location":             "Denver Warehouse",
        "BinRack":              f"BIN-{random.randint(1,50):02d}-{random.randint(1,20):02d}",
        "Date":                 iso(occurred),
        "StockValue":           round(abs(qty_change) * stock_item["CostPrice"], 2),
        # Running balance NOT provided by Linnworks —
        # must be reconstructed from transaction history
        "_note": "Running balance must be reconstructed by replaying transactions"
                 if tx_type == "DISPATCH" else "",
    }


# ══════════════════════════════════════════════════════════════════════════════
#  FILE WRITERS
# ══════════════════════════════════════════════════════════════════════════════

def write_json(folder, filename, payload):
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, filename), "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, ensure_ascii=False)


def write_paginated(records, base_folder, label):
    """
    Linnworks pagination uses PageNumber + HasMorePages,
    not a cursor like Onfleet.
    """
    pages      = [records[i:i+PAGE_SIZE] for i in range(0, len(records), PAGE_SIZE)]
    total_pages = len(pages)

    for idx, page in enumerate(pages, start=1):
        payload = {
            # Linnworks pagination envelope
            "PageNumber":   idx,
            "TotalPages":   total_pages,
            "HasMorePages": idx < total_pages,
            "TotalRecords": len(records),
            "Data":         page,
        }
        folder   = base_folder
        filename = f"page_{str(idx).zfill(4)}.json"
        write_json(folder, filename, payload)

    return total_pages


# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════

def main():
    print("SwiftRoute — Linnworks raw data generator")
    print("=" * 45)

    # ── Build stock items ──────────────────────────────────────────────────────
    print("Building stock catalogue...")
    stock_items, sku_registry = build_stock_items()
    print(f"  SKUs generated : {len(stock_items)} "
          f"(includes {sum(1 for s in stock_items if '_' in s['ItemNumber'].split('-')[0].lower())} duplicates)")

    # Write stock items as a single file (not paginated — catalogue is static)
    stock_folder = os.path.join(OUTPUT_BASE, "stock_items")
    write_json(stock_folder, "stock_items.json", {
        "TotalRecords": len(stock_items),
        "Data":         stock_items,
    })
    print(f"  Written to     : stock_items/stock_items.json")
    print()

    # Group stock items by client for order generation
    items_by_client = {}
    for itm in stock_items:
        cid = itm["_swiftroute_client_id"]
        items_by_client.setdefault(cid, []).append(itm)

    # ── Generate processed orders & stock transactions ─────────────────────────
    print("Generating processed orders and stock transactions...")
    print()

    total_orders       = 0
    total_transactions = 0
    all_order_refs     = []   # collect order refs for orphan injection

    date = START_DATE
    while date <= END_DATE:
        month_key    = f"{date.year}_{str(date.month).zfill(2)}"
        month_orders = []
        month_txns   = []

        # Generate one full month
        month_start = date
        while date <= END_DATE and date.month == month_start.month:

            day_mult = seasonal_mult(date) * DOW_MULT[date.weekday()]

            for client in FULFILLMENT_CLIENTS:
                lo, hi   = client["daily_orders"]
                vol      = max(1, int(random.randint(lo, hi) * day_mult))
                items_pool = items_by_client.get(client["id"], [])
                if not items_pool:
                    date += timedelta(days=1)
                    continue

                for _ in range(vol):
                    order = make_processed_order(date, client, items_pool)
                    month_orders.append(order)
                    all_order_refs.append(order["ReferenceNum"])

                    # Stock transactions for each line item in this order
                    for line in order["Items"]:
                        sku_item = next(
                            (s for s in items_pool
                             if s["ItemNumber"] == line["SKU"]), None)
                        if not sku_item:
                            continue

                        # DISPATCH transaction (negative qty = stock out)
                        month_txns.append(make_transaction(
                            date, sku_item,
                            tx_type="DISPATCH",
                            qty_change=-line["Quantity"],
                            order_ref=order["ReferenceNum"],
                        ))

                # Supplier receipts: roughly every 2 weeks per client
                if date.day in (1, 7, 14, 21, 28):
                    for itm in random.sample(items_pool,
                                             min(5, len(items_pool))):
                        receipt_qty = random.randint(50, 300)
                        month_txns.append(make_transaction(
                            date, itm,
                            tx_type="RECEIPT",
                            qty_change=receipt_qty,
                        ))

                # Adjustments: occasional manual corrections
                if random.random() < 0.03:
                    adj_item = random.choice(items_pool)
                    adj_qty  = random.randint(-10, 10)
                    month_txns.append(make_transaction(
                        date, adj_item,
                        tx_type="ADJUSTMENT",
                        qty_change=adj_qty,
                    ))

            date += timedelta(days=1)

        # Inject NEGATIVE STOCK quirk: a few dispatches recorded before receipt
        neg_count = random.randint(3, 8)
        for _ in range(neg_count):
            client   = random.choice(FULFILLMENT_CLIENTS)
            itm_pool = items_by_client.get(client["id"], [])
            if itm_pool:
                itm = random.choice(itm_pool)
                # Large dispatch that exceeds current stock —
                # creates a negative balance
                month_txns.append(make_transaction(
                    month_start + timedelta(days=random.randint(0,27)),
                    itm,
                    tx_type="DISPATCH",
                    qty_change=-random.randint(50, 150),
                ))

        # Inject ORPHANED TRANSACTION quirk
        orphan_count = random.randint(2, 5)
        for _ in range(orphan_count):
            client   = random.choice(FULFILLMENT_CLIENTS)
            itm_pool = items_by_client.get(client["id"], [])
            if itm_pool:
                itm = random.choice(itm_pool)
                month_txns.append(make_transaction(
                    month_start + timedelta(days=random.randint(0, 27)),
                    itm,
                    tx_type="DISPATCH",
                    qty_change=-random.randint(1, 5),
                    is_orphan=True,  # references a deleted order
                ))

        # Sort by date so pages are chronological
        month_orders.sort(key=lambda x: x["ProcessedOn"])
        month_txns.sort(key=lambda x: x["Date"])

        # Write processed orders pages
        orders_folder = os.path.join(OUTPUT_BASE, "processed_orders", month_key)
        op = write_paginated(month_orders, orders_folder, "orders")

        # Write stock transactions pages
        txns_folder = os.path.join(OUTPUT_BASE, "stock_transactions", month_key)
        tp = write_paginated(month_txns, txns_folder, "transactions")

        total_orders       += len(month_orders)
        total_transactions += len(month_txns)

        print(f"  {month_key}: {len(month_orders):>6,} orders  "
              f"({op:>3} pages)  |  "
              f"{len(month_txns):>6,} transactions  ({tp:>3} pages)")

    # ── Summary ────────────────────────────────────────────────────────────────
    print()
    print("=" * 45)
    print(f"Stock items         : {len(stock_items):,}")
    print(f"Processed orders    : {total_orders:,}")
    print(f"Stock transactions  : {total_transactions:,}")
    print(f"Output folder       : {OUTPUT_BASE}")
    print()
    print("Key things to find when you open these files:")
    print("  1. stock_items.json     — look for SKUs with _ vs -")
    print("  2. stock_transactions   — look for negative Quantity values")
    print("  3. stock_transactions   — look for fkOrderId starting with DELETED-")
    print("  4. Dates are ISO strings here, NOT milliseconds like Onfleet")
    print("  5. Pagination uses HasMorePages/PageNumber, not lastId cursor")


if __name__ == "__main__":
    main()
