import os
import json
import logging
import psycopg2
from dotenv import load_dotenv
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
log = logging.getLogger(__name__)

load_dotenv()

DB_CONFIG = {
    "host": os.getenv("DB_HOST"),
    "port": os.getenv("DB_PORT"),
    "dbname": os.getenv("DB_NAME"),
    "user": os.getenv("DB_USER"),
    "password": os.getenv("DB_PASSWORD"),
}

SOURCE_SYSTEM = "linnworks"
SOURCE_FOLDER = Path("source_data/raw/linnworks")


def get_connection():
    return psycopg2.connect(**DB_CONFIG)


def is_file_processed(cursor, source_file):
    cursor.execute(
        "SELECT 1 FROM bronze.pipeline_state WHERE source_system = %s AND source_file = %s",
        (SOURCE_SYSTEM, source_file)
    )
    return cursor.fetchone() is not None


def mark_file_processed(cursor, source_file, record_count):
    cursor.execute(
        """
        INSERT INTO bronze.pipeline_state (source_system, source_file, record_count)
        VALUES (%s, %s, %s)
        ON CONFLICT (source_system, source_file) DO NOTHING
        """,
        (SOURCE_SYSTEM, source_file, record_count)
    )


def ensure_bronze_tables(cursor):
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS bronze.linnworks_orders (
            id               SERIAL PRIMARY KEY,
            ingest_timestamp TIMESTAMP NOT NULL DEFAULT NOW(),
            source_file      VARCHAR   NOT NULL,
            raw_data         JSONB     NOT NULL
        )
    """)
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS bronze.linnworks_inventory (
            id               SERIAL PRIMARY KEY,
            ingest_timestamp TIMESTAMP NOT NULL DEFAULT NOW(),
            source_file      VARCHAR   NOT NULL,
            raw_data         JSONB     NOT NULL
        )
    """)
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS bronze.linnworks_stock_transactions (
            id               SERIAL PRIMARY KEY,
            ingest_timestamp TIMESTAMP NOT NULL DEFAULT NOW(),
            source_file      VARCHAR   NOT NULL,
            raw_data         JSONB     NOT NULL
        )
    """)


def load_paginated_file(cursor, file_path, relative_path, table, envelope_key):
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            payload = json.load(f)

        records = payload.get(envelope_key, [])

        if not records:
            log.info(f"No records in {relative_path}, skipping.")
            return 0

        for record in records:
            cursor.execute(
                f"INSERT INTO bronze.{table} (source_file, raw_data) VALUES (%s, %s)",
                (relative_path, json.dumps(record))
            )

        log.info(f"Loaded {len(records)} records from {relative_path} into {table}")
        return len(records)

    except Exception as e:
        log.error(f"Failed to load {relative_path}: {e}")
        return None


def run():
    conn = get_connection()
    conn.autocommit = False

    try:
        with conn.cursor() as cur:
            ensure_bronze_tables(cur)
            conn.commit()

            # processed_orders
            orders_folder = SOURCE_FOLDER / "processed_orders"
            for month_folder in sorted(orders_folder.iterdir()):
                if not month_folder.is_dir():
                    continue
                for page_file in sorted(month_folder.glob("*.json")):
                    relative_path = f"processed_orders/{month_folder.name}/{page_file.name}"
                    if is_file_processed(cur, relative_path):
                        log.info(f"Already processed: {relative_path}, skipping.")
                        continue
                    count = load_paginated_file(cur, page_file, relative_path, "linnworks_orders", "Data")
                    if count is not None:
                        mark_file_processed(cur, relative_path, count)
                        conn.commit()
                    else:
                        conn.rollback()

            # stock_items (single file)
            stock_file = SOURCE_FOLDER / "stock_items" / "stock_items.json"
            relative_path = "stock_items/stock_items.json"
            if not is_file_processed(cur, relative_path):
                count = load_paginated_file(cur, stock_file, relative_path, "linnworks_inventory", "Data")
                if count is not None:
                    mark_file_processed(cur, relative_path, count)
                    conn.commit()
                else:
                    conn.rollback()

            # stock_transactions
            transactions_folder = SOURCE_FOLDER / "stock_transactions"
            for month_folder in sorted(transactions_folder.iterdir()):
                if not month_folder.is_dir():
                    continue
                for page_file in sorted(month_folder.glob("*.json")):
                    relative_path = f"stock_transactions/{month_folder.name}/{page_file.name}"
                    if is_file_processed(cur, relative_path):
                        log.info(f"Already processed: {relative_path}, skipping.")
                        continue
                    count = load_paginated_file(cur, page_file, relative_path, "linnworks_stock_transactions", "Data")
                    if count is not None:
                        mark_file_processed(cur, relative_path, count)
                        conn.commit()
                    else:
                        conn.rollback()

    except Exception as e:
        log.error(f"Fatal error: {e}")
        conn.rollback()
    finally:
        conn.close()


if __name__ == "__main__":
    run()