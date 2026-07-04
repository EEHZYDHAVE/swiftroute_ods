"""
generators/generate_linnworks.py

Generates synthetic Linnworks API responses for SwiftRoute Logistics.
Imports CLIENTS from shared_ids.py (written by generate_shared_ids.py,
which must run first) — shared_ids.py is authoritative for client
identity. Only the 11 fulfillment clients (is_fulfillment == True) are
relevant here; everything else this generator produces (stock items,
orders, transactions) is Linnworks' own internal data, not shared
across systems, so it isn't sourced from shared_ids.

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
  source_data/raw/linnworks/processed_orders/{YYYY_MM}/page_{NNNN}.json
  source_data/raw/linnworks/stock_items/stock_items.json
  source_data/raw/linnworks/stock_transactions/{YYYY_MM}/page_{NNNN}.json

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
OUTPUT_BASE  = os.path.join(PROJECT_ROOT, "source_data", "raw", "linnworks")

START_DATE = datetime(2025, 1,  1, tzinfo=timezone.utc)
END_DATE   = datetime(2025, 6, 30, tzinfo=timezone.utc)
PAGE_SIZE = 100

CATEGORIES = ["Apparel","Footwear","Skincare","Nutrition","Home & Garden",
               "Pet Supplies","Outdoor Gear","Food & Beverage","Gifts","Candles"]
CHANNELS   = ["SHOPIFY","WOOCOMMERCE","AMAZON","DIRECT","ETSY"]


def build_fulfillment_clients():
    """The 11 fulfillment clients, sourced from shared_ids.CLIENTS —
    not invented locally. sku_prefix, sku_count, and daily order range
    are already decided there per client."""
    clients = []
    for c in shared_ids.CLIENTS:
        if not c["is_fulfillment"]:
            continue
        clients.append({
            "id":           c["internal_id"],
            "name":         c["name"],
            "tier":         c["tier"],
            "sku_prefix":   c["sku_prefix"],
            "sku_count":    c["sku_count"],
            "daily_orders": (c["daily_orders_lo"], c["daily_orders_hi"]),
        })
    return clients


def lw_guid():
    h = lambda n: "".join(random.choices(string.hexdigits[:16], k=n))
    return f"{h(8)}-{h(4)}-{h(4)}-{h(4)}-{h(12)}".upper()

def lw_order_id():
    return f"ORD-{random.randint(100000, 999999)}"

def lw_ref():
    return f"LW{random.randint(10000000, 99999999)}"

def ms(dt):
    return int(dt.timestamp() * 1000)

def iso(dt):
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


# ══════════════════════════════════════════════════════════════════════════
#  STOCK ITEMS — product catalogue
# ══════════════════════════════════════════════════════════════════════════

def build_stock_items(fulfillment_clients):
    """
    QUIRK: SKU inconsistency — for ~8% of items, a duplicate entry exists
    with a slightly different SKU format (underscore vs hyphen, or lowercase).
    """
    random.seed(300)
    Faker.seed(300)

    items = []
    sku_registry = {}

    for client in fulfillment_clients:
        prefix = client["sku_prefix"]
        for i in range(client["sku_count"]):
            item_id = lw_guid()
            sku_clean = f"{prefix}-{random.choice(['A','B','C','D','E'])}{str(i+1).zfill(3)}"

            introduce_dup = random.random() < 0.08
            sku_used = sku_clean

            weight_g = random.randint(50, 5000)
            dims_cm = {
                "Width":  round(random.uniform(3, 40), 1),
                "Height": round(random.uniform(2, 30), 1),
                "Depth":  round(random.uniform(2, 35), 1),
            }
            cost_price = round(random.uniform(2.50, 85.00), 2)
            retail = round(cost_price * random.uniform(1.8, 4.5), 2)
            qty_on_hand = random.randint(0, 400)

            item = {
                "StockItemId":       item_id,
                "ItemNumber":        sku_used,
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
                "Quantity":          qty_on_hand,
                "MinimumLevel":      random.randint(5, 30),
                "InOrderBook":       random.randint(0, 20),
                "Due":               random.randint(0, 50),
                "JIT":               False,
                "CreationDate":      iso(START_DATE - timedelta(days=random.randint(30, 365))),
                "ModifiedDate":      iso(START_DATE - timedelta(days=random.randint(0, 30))),
                "Source":            "DIRECT",
                "IsDeleted":         False,
                "_swiftroute_client_id":   client["id"],
                "_swiftroute_client_name": client["name"],
            }
            items.append(item)
            sku_registry[sku_used] = item_id

            if introduce_dup:
                bad_sku = sku_clean.replace("-", "_").lower()
                dup_item = dict(item)
                dup_item["StockItemId"] = lw_guid()
                dup_item["ItemNumber"] = bad_sku
                dup_item["Quantity"] = random.randint(0, 50)
                dup_item["CreationDate"] = iso(START_DATE - timedelta(days=random.randint(1, 20)))
                items.append(dup_item)
                sku_registry[bad_sku] = dup_item["StockItemId"]

    random.seed(SEED)
    Faker.seed(SEED)
    return items, sku_registry


# ══════════════════════════════════════════════════════════════════════════
#  PROCESSED ORDERS
# ══════════════════════════════════════════════════════════════════════════

def make_processed_order(date, client, stock_items_for_client):
    order_id = lw_guid()
    processed_at = date.replace(
        hour=random.randint(6, 17), minute=random.randint(0, 59),
        second=random.randint(0, 59), microsecond=0,
    )
    dispatched_at = processed_at + timedelta(minutes=random.randint(15, 120))

    num_lines = random.choices([1,2,3,4], weights=[0.50,0.30,0.15,0.05])[0]
    chosen = random.sample(stock_items_for_client, min(num_lines, len(stock_items_for_client)))

    order_items = []
    subtotal = 0.0
    for itm in chosen:
        qty = random.randint(1, 3)
        unit_price = itm["RetailPrice"]
        line_total = round(qty * unit_price, 2)
        subtotal += line_total
        order_items.append({
            "StockItemId": itm["StockItemId"],
            "SKU": itm["ItemNumber"],
            "ItemTitle": itm["ItemTitle"],
            "Quantity": qty,
            "UnitCost": itm["CostPrice"],
            "PricePerUnit": unit_price,
            "LineTotal": line_total,
            "Weight": itm["Weight"] * qty,
            "IsComposite": False,
            "BinRack": f"BIN-{random.randint(1,50):02d}-{random.randint(1,20):02d}",
        })

    shipping_cost = round(random.uniform(0, 12), 2)
    total_cost = round(subtotal + shipping_cost, 2)
    channel = random.choice(CHANNELS)

    return {
        "pkOrderID": order_id,
        "NumOrderId": random.randint(10000, 999999),
        "ReferenceNum": lw_ref(),
        "ExternalReference": f"{channel}-{random.randint(100000,999999)}",
        "SecondaryReference": "",
        "Channel": channel,
        "Source": channel,
        "SubSource": client["name"],
        "SiteCode": "DENVER-WH",
        "FulfilmentLocationName": "Denver Warehouse",
        "ReceivedDate": iso(processed_at - timedelta(minutes=random.randint(5, 60))),
        "ProcessedOn": iso(processed_at),
        "DispatchedOn": iso(dispatched_at),
        "CustomerName": fake.name(),
        "CustomerEmail": fake.email(),
        "Address": {
            "FullName": fake.name(), "Company": "", "Address1": fake.street_address(),
            "Address2": "", "City": fake.city(), "Region": fake.state(),
            "PostCode": fake.postcode(), "Country": "United States", "CountryCode": "US",
            "Phone": fake.phone_number(),
        },
        "SubTotal": round(subtotal, 2),
        "PostalServiceCost": shipping_cost,
        "TotalCharge": total_cost,
        "TaxAmount": round(total_cost * 0.08, 2),
        "Currency": "USD",
        "PaymentMethod": random.choice(["SHOPIFY_PAYMENTS","PAYPAL","STRIPE","AMAZON_PAY"]),
        "PaymentStatus": "PAID",
        "GeneralInfo": {
            "Status": 3, "LockForShipping": False, "Marker": 0,
            "Notes": random.choice(["","","Gift — no invoice","Fragile items"]),
        },
        "ShippingInfo": {
            "PostalServiceName": "SwiftRoute Same Day" if random.random() < 0.35 else "SwiftRoute Next Day",
            "TrackingNumber": f"SR{random.randint(1000000000, 9999999999)}",
            "Vendor": "SwiftRoute Logistics",
            "PostalServiceCode": "SR-SD" if random.random() < 0.35 else "SR-ND",
        },
        "Items": order_items,
        "_swiftroute_client_id": client["id"],
        "_swiftroute_client_name": client["name"],
        "_swiftroute_pick_duration_mins": random.randint(3, 18),
    }


# ══════════════════════════════════════════════════════════════════════════
#  STOCK TRANSACTIONS
# ══════════════════════════════════════════════════════════════════════════

TRANSACTION_TYPES = {
    "DISPATCH":   "Stock removed for a processed order",
    "RECEIPT":    "Stock received from supplier",
    "ADJUSTMENT": "Manual stock count correction",
    "RETURN":     "Customer return restocked",
    "TRANSFER":   "Stock moved between bin locations",
    "WRITE_OFF":  "Damaged or expired stock removed",
}

def make_transaction(date, stock_item, tx_type, qty_change, order_ref=None, is_orphan=False):
    occurred = date.replace(
        hour=random.randint(6, 20), minute=random.randint(0, 59),
        second=random.randint(0, 59), microsecond=0,
    )
    ref = order_ref
    if is_orphan:
        ref = f"DELETED-ORD-{random.randint(10000,99999)}"

    return {
        "pkStockTransactionId": lw_guid(),
        "fkStockItemId": stock_item["StockItemId"],
        "SKU": stock_item["ItemNumber"],
        "ItemTitle": stock_item["ItemTitle"],
        "TransactionType": tx_type,
        "TransactionNote": TRANSACTION_TYPES[tx_type],
        "Quantity": qty_change,
        "fkOrderId": ref,
        "Location": "Denver Warehouse",
        "BinRack": f"BIN-{random.randint(1,50):02d}-{random.randint(1,20):02d}",
        "Date": iso(occurred),
        "StockValue": round(abs(qty_change) * stock_item["CostPrice"], 2),
        "_note": "Running balance must be reconstructed by replaying transactions"
                 if tx_type == "DISPATCH" else "",
    }


# ══════════════════════════════════════════════════════════════════════════
#  FILE WRITERS
# ══════════════════════════════════════════════════════════════════════════

def write_json(folder, filename, payload):
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, filename), "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, ensure_ascii=False)


def write_paginated(records, base_folder, label):
    pages = [records[i:i+PAGE_SIZE] for i in range(0, len(records), PAGE_SIZE)]
    total_pages = len(pages)
    for idx, page in enumerate(pages, start=1):
        payload = {
            "PageNumber": idx, "TotalPages": total_pages,
            "HasMorePages": idx < total_pages, "TotalRecords": len(records),
            "Data": page,
        }
        write_json(base_folder, f"page_{str(idx).zfill(4)}.json", payload)
    return total_pages


# ══════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════

def main():
    print("SwiftRoute — Linnworks raw data generator")
    print("=" * 45)

    fulfillment_clients = build_fulfillment_clients()
    print(f"Fulfillment clients: {len(fulfillment_clients)}  (sourced from shared_ids.CLIENTS)")

    print("Building stock catalogue...")
    stock_items, sku_registry = build_stock_items(fulfillment_clients)
    print(f"  SKUs generated : {len(stock_items)} "
          f"(includes {sum(1 for s in stock_items if '_' in s['ItemNumber'].split('-')[0].lower())} duplicates)")

    stock_folder = os.path.join(OUTPUT_BASE, "stock_items")
    write_json(stock_folder, "stock_items.json", {
        "TotalRecords": len(stock_items),
        "Data": stock_items,
    })
    print(f"  Written to     : stock_items/stock_items.json")
    print()

    items_by_client = {}
    for itm in stock_items:
        cid = itm["_swiftroute_client_id"]
        items_by_client.setdefault(cid, []).append(itm)

    print("Generating processed orders and stock transactions...")
    print()

    total_orders = 0
    total_transactions = 0
    all_order_refs = []

    date = START_DATE
    while date <= END_DATE:
        month_key = f"{date.year}_{str(date.month).zfill(2)}"
        month_orders = []
        month_txns = []
        month_start = date

        while date <= END_DATE and date.month == month_start.month:
            day_mult = seasonal_mult(date) * DOW_MULT[date.weekday()]

            for client in fulfillment_clients:
                lo, hi = client["daily_orders"]
                vol = max(1, int(random.randint(lo, hi) * day_mult))
                items_pool = items_by_client.get(client["id"], [])
                if not items_pool:
                    continue

                for _ in range(vol):
                    order = make_processed_order(date, client, items_pool)
                    month_orders.append(order)
                    all_order_refs.append(order["ReferenceNum"])

                    for line in order["Items"]:
                        sku_item = next((s for s in items_pool if s["ItemNumber"] == line["SKU"]), None)
                        if not sku_item:
                            continue
                        month_txns.append(make_transaction(
                            date, sku_item, tx_type="DISPATCH",
                            qty_change=-line["Quantity"], order_ref=order["ReferenceNum"],
                        ))

                if date.day in (1, 7, 14, 21, 28):
                    for itm in random.sample(items_pool, min(5, len(items_pool))):
                        receipt_qty = random.randint(50, 300)
                        month_txns.append(make_transaction(date, itm, tx_type="RECEIPT", qty_change=receipt_qty))

                if random.random() < 0.03:
                    adj_item = random.choice(items_pool)
                    adj_qty = random.randint(-10, 10)
                    month_txns.append(make_transaction(date, adj_item, tx_type="ADJUSTMENT", qty_change=adj_qty))

            date += timedelta(days=1)

        neg_count = random.randint(3, 8)
        for _ in range(neg_count):
            client = random.choice(fulfillment_clients)
            itm_pool = items_by_client.get(client["id"], [])
            if itm_pool:
                itm = random.choice(itm_pool)
                month_txns.append(make_transaction(
                    month_start + timedelta(days=random.randint(0,27)),
                    itm, tx_type="DISPATCH", qty_change=-random.randint(50, 150),
                ))

        orphan_count = random.randint(2, 5)
        for _ in range(orphan_count):
            client = random.choice(fulfillment_clients)
            itm_pool = items_by_client.get(client["id"], [])
            if itm_pool:
                itm = random.choice(itm_pool)
                month_txns.append(make_transaction(
                    month_start + timedelta(days=random.randint(0, 27)),
                    itm, tx_type="DISPATCH", qty_change=-random.randint(1, 5), is_orphan=True,
                ))

        month_orders.sort(key=lambda x: x["ProcessedOn"])
        month_txns.sort(key=lambda x: x["Date"])

        orders_folder = os.path.join(OUTPUT_BASE, "processed_orders", month_key)
        op = write_paginated(month_orders, orders_folder, "orders")

        txns_folder = os.path.join(OUTPUT_BASE, "stock_transactions", month_key)
        tp = write_paginated(month_txns, txns_folder, "transactions")

        total_orders += len(month_orders)
        total_transactions += len(month_txns)

        print(f"  {month_key}: {len(month_orders):>6,} orders  ({op:>3} pages)  |  "
              f"{len(month_txns):>6,} transactions  ({tp:>3} pages)")

    print()
    print("=" * 45)
    print(f"Stock items         : {len(stock_items):,}")
    print(f"Processed orders    : {total_orders:,}")
    print(f"Stock transactions  : {total_transactions:,}")
    print(f"Output folder       : {OUTPUT_BASE}")


if __name__ == "__main__":
    main()