"""
loader: load_gusto.py
source system: Gusto (HR & Payroll)
bronze tables: bronze.gusto_employees
               bronze.gusto_payroll_runs
               bronze.gusto_payroll_compensations

Reads from source_data/raw/gusto/:
- employees/employees.json — single file, raw array of employee records
- payrolls/payroll_YYYY-MM-DD.json — one file per payroll run

Each payroll file is split into two record types:
- The payroll header (excluding compensations) → gusto_payroll_runs
- Each employee_compensation entry → gusto_payroll_compensations

Tracks processed files in bronze.pipeline_state to support incremental loading.
"""

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

SOURCE_SYSTEM = "gusto"
SOURCE_FOLDER = Path("source_data/raw/gusto")


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
        CREATE TABLE IF NOT EXISTS bronze.gusto_employees (
            id               SERIAL PRIMARY KEY,
            ingest_timestamp TIMESTAMP NOT NULL DEFAULT NOW(),
            source_file      VARCHAR   NOT NULL,
            raw_data         JSONB     NOT NULL
        )
    """)
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS bronze.gusto_payroll_runs (
            id               SERIAL PRIMARY KEY,
            ingest_timestamp TIMESTAMP NOT NULL DEFAULT NOW(),
            source_file      VARCHAR   NOT NULL,
            raw_data         JSONB     NOT NULL
        )
    """)
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS bronze.gusto_payroll_compensations (
            id               SERIAL PRIMARY KEY,
            ingest_timestamp TIMESTAMP NOT NULL DEFAULT NOW(),
            source_file      VARCHAR   NOT NULL,
            raw_data         JSONB     NOT NULL
        )
    """)


def load_employees(cursor):
    file_path = SOURCE_FOLDER / "employees" / "employees.json"
    relative_path = "employees/employees.json"

    if is_file_processed(cursor, relative_path):
        log.info(f"Already processed: {relative_path}, skipping.")
        return

    try:
        with open(file_path, "r", encoding="utf-8") as f:
            records = json.load(f)

        for record in records:
            cursor.execute(
                "INSERT INTO bronze.gusto_employees (source_file, raw_data) VALUES (%s, %s)",
                (relative_path, json.dumps(record))
            )

        log.info(f"Loaded {len(records)} records from {relative_path}")
        mark_file_processed(cursor, relative_path, len(records))

    except Exception as e:
        log.error(f"Failed to load {relative_path}: {e}")


def load_payrolls(cursor):
    payrolls_folder = SOURCE_FOLDER / "payrolls"

    for file_path in sorted(payrolls_folder.glob("*.json")):
        relative_path = f"payrolls/{file_path.name}"

        if is_file_processed(cursor, relative_path):
            log.info(f"Already processed: {relative_path}, skipping.")
            continue

        try:
            with open(file_path, "r", encoding="utf-8") as f:
                payload = json.load(f)

            # Load payroll run header (excluding employee_compensations)
            payroll_header = {k: v for k, v in payload.items() if k != "employee_compensations"}
            cursor.execute(
                "INSERT INTO bronze.gusto_payroll_runs (source_file, raw_data) VALUES (%s, %s)",
                (relative_path, json.dumps(payroll_header))
            )

            # Load each compensation as a separate record
            compensations = payload.get("employee_compensations", [])
            for comp in compensations:
                cursor.execute(
                    "INSERT INTO bronze.gusto_payroll_compensations (source_file, raw_data) VALUES (%s, %s)",
                    (relative_path, json.dumps(comp))
                )

            total = 1 + len(compensations)
            log.info(f"Loaded 1 payroll run + {len(compensations)} compensations from {relative_path}")
            mark_file_processed(cursor, relative_path, total)

        except Exception as e:
            log.error(f"Failed to load {relative_path}: {e}")


def run():
    conn = get_connection()
    conn.autocommit = False

    try:
        with conn.cursor() as cur:
            ensure_bronze_tables(cur)
            conn.commit()

            load_employees(cur)
            conn.commit()

            load_payrolls(cur)
            conn.commit()

    except Exception as e:
        log.error(f"Fatal error: {e}")
        conn.rollback()
    finally:
        conn.close()


if __name__ == "__main__":
    run()