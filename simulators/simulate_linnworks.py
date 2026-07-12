"""
simulators/simulate_linnworks.py

Incremental Linnworks simulator. Reuses generate_linnworks.py's own
make_processed_order() / make_transaction() functions directly.
stock_items.json is NEVER touched (no new inventory in scope) — instead,
the EXISTING stock_items.json is read from disk so new orders/transactions
reference the exact same StockItemId values already on record.
"""

import os
import sys
import json
import random
import argparse
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "generators"))

import _common
import generate_linnworks as lw

SEED = 42


def run(start_date, end_date):
    print(f"[linnworks] simulating {start_date} -> {end_date}")

    with open(_common.system_path("linnworks", "stock_items", "stock_items.json")) as fh:
        stock_payload = json.load(fh)
    stock_items = stock_payload["Data"]

    fulfillment_clients = lw.build_fulfillment_clients()
    items_by_client = {}
    for itm in stock_items:
        cid = itm["_swiftroute_client_id"]
        items_by_client.setdefault(cid, []).append(itm)

    random.seed(SEED)

    orders_by_month = {}
    txns_by_month = {}
    total_orders = 0
    total_txns = 0

    for d in _common.daterange(start_date, end_date):
        dt = datetime(d.year, d.month, d.day, tzinfo=timezone.utc)
        mk = _common.month_key(d)
        day_mult = lw.seasonal_mult(dt) * lw.DOW_MULT[dt.weekday()]

        for client in fulfillment_clients:
            lo, hi = client["daily_orders"]
            vol = max(1, int(random.randint(lo, hi) * day_mult))
            items_pool = items_by_client.get(client["id"], [])
            if not items_pool:
                continue

            for _ in range(vol):
                order = lw.make_processed_order(dt, client, items_pool)
                orders_by_month.setdefault(mk, []).append(order)
                total_orders += 1

                for line in order["Items"]:
                    sku_item = next((s for s in items_pool if s["ItemNumber"] == line["SKU"]), None)
                    if not sku_item:
                        continue
                    txns_by_month.setdefault(mk, []).append(lw.make_transaction(
                        dt, sku_item, tx_type="DISPATCH",
                        qty_change=-line["Quantity"], order_ref=order["ReferenceNum"],
                    ))

            if d.day in (1, 7, 14, 21, 28):
                for itm in random.sample(items_pool, min(5, len(items_pool))):
                    receipt_qty = random.randint(50, 300)
                    txns_by_month.setdefault(mk, []).append(
                        lw.make_transaction(dt, itm, tx_type="RECEIPT", qty_change=receipt_qty))

            if random.random() < 0.03:
                adj_item = random.choice(items_pool)
                adj_qty = random.randint(-10, 10)
                txns_by_month.setdefault(mk, []).append(
                    lw.make_transaction(dt, adj_item, tx_type="ADJUSTMENT", qty_change=adj_qty))

    if random.random() < 0.5:
        client = random.choice(fulfillment_clients)
        itm_pool = items_by_client.get(client["id"], [])
        if itm_pool:
            itm = random.choice(itm_pool)
            mk = _common.month_key(start_date)
            dt = datetime(start_date.year, start_date.month, start_date.day, tzinfo=timezone.utc)
            txns_by_month.setdefault(mk, []).append(
                lw.make_transaction(dt, itm, tx_type="DISPATCH", qty_change=-random.randint(1, 5), is_orphan=True))

    for mk, orders in orders_by_month.items():
        orders.sort(key=lambda x: x["ProcessedOn"])
        folder = _common.system_path("linnworks", "processed_orders", mk)
        start_page = _common.next_page_number(folder)
        pages = [orders[i:i + lw.PAGE_SIZE] for i in range(0, len(orders), lw.PAGE_SIZE)]
        for i, page in enumerate(pages):
            payload = {
                "PageNumber": start_page + i, "TotalPages": len(pages),
                "HasMorePages": i < len(pages) - 1, "TotalRecords": len(orders),
                "Data": page,
            }
            _common.write_json(os.path.join(folder, f"page_{str(start_page + i).zfill(4)}.json"), payload)
        print(f"  {mk}: +{len(orders)} orders -> {len(pages)} new page(s) starting at page_{str(start_page).zfill(4)}")

    for mk, txns in txns_by_month.items():
        txns.sort(key=lambda x: x["Date"])
        folder = _common.system_path("linnworks", "stock_transactions", mk)
        start_page = _common.next_page_number(folder)
        pages = [txns[i:i + lw.PAGE_SIZE] for i in range(0, len(txns), lw.PAGE_SIZE)]
        for i, page in enumerate(pages):
            payload = {
                "PageNumber": start_page + i, "TotalPages": len(pages),
                "HasMorePages": i < len(pages) - 1, "TotalRecords": len(txns),
                "Data": page,
            }
            _common.write_json(os.path.join(folder, f"page_{str(start_page + i).zfill(4)}.json"), payload)
        print(f"  {mk}: +{len(txns)} transactions -> {len(pages)} new page(s) starting at page_{str(start_page).zfill(4)}")
        total_txns += len(txns)

    print(f"[linnworks] done. +{total_orders} orders, +{total_txns} transactions. stock_items.json untouched.")
    return total_orders


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--start-date", required=True)
    parser.add_argument("--end-date", required=True)
    args = parser.parse_args()
    s = datetime.strptime(args.start_date, "%Y-%m-%d").date()
    e = datetime.strptime(args.end_date, "%Y-%m-%d").date()
    run(s, e)
