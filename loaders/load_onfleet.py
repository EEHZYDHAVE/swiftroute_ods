"""
loader: load_onfleet.py
source system: Onfleet (Delivery Management)
bronze tables:
    bronze.onfleet_deliveries    — delivery/pickup task records
    bronze.onfleet_workers  — driver roster (name resolvable here only;
                              task records only ever carry a worker ID)

Reads two distinct shapes from source_data/raw/onfleet/:
  1. Paginated task files — {month}/page_XXXX.json
     Each file contains a 'tasks' array of raw delivery records.
     Loaded into bronze.onfleet_deliveries as JSONB, one row per task.
  2. A single static file — workers/workers.json
     A plain JSON array (NOT wrapped in a 'tasks' envelope) of worker
     records. Loaded into bronze.onfleet_workers as JSONB, one row per
     worker. Not paginated — Onfleet's real Workers endpoint returns
     the full roster in one response.

Records are inserted as-is into their respective bronze table as JSONB.
Tracks processed files in bronze.pipeline_state (keyed by source_system +
source_file) to support incremental loading, across both the task pages
and the workers file. On first run, all files are loaded. On subsequent
runs, only new files are processed.
"""

import os
import json
import logging
import psycopg2
from dotenv import load_dotenv
from pathlib import Path

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
log = logging.getLogger(__name__)

# Load environment variables
load_dotenv()

DB_CONFIG = {
    "host": os.getenv("DB_HOST"),
    "port": os.getenv("DB_PORT"),
    "dbname": os.getenv("DB_NAME"),
    "user": os.getenv("DB_USER"),
    "password": os.getenv("DB_PASSWORD"),
}

SOURCE_SYSTEM = "onfleet"
SOURCE_FOLDER = Path("source_data/raw/onfleet")
WORKERS_FOLDER_NAME = "workers"   # not a month folder — handled separately


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
        CREATE TABLE IF NOT EXISTS bronze.onfleet_deliveries (
            id               SERIAL PRIMARY KEY,
            ingest_timestamp TIMESTAMP NOT NULL DEFAULT NOW(),
            source_file      VARCHAR   NOT NULL,
            raw_data         JSONB     NOT NULL
        )
    """)
    # Separate table for workers — different entity, different shape
    # (a plain array, not a {"tasks": [...]} page envelope)
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS bronze.onfleet_workers (
            id               SERIAL PRIMARY KEY,
            ingest_timestamp TIMESTAMP NOT NULL DEFAULT NOW(),
            source_file      VARCHAR   NOT NULL,
            raw_data         JSONB     NOT NULL
        )
    """)


def load_task_file(cursor, file_path, relative_path):
    """Loads one page of Onfleet tasks — payload is {"tasks": [...], "lastId": ...}."""
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            payload = json.load(f)

        records = payload.get("tasks", [])

        if not records:
            log.info(f"No tasks found in {relative_path}, skipping.")
            return 0

        for record in records:
            cursor.execute(
                """
                INSERT INTO bronze.onfleet_deliveries (source_file, raw_data)
                VALUES (%s, %s)
                """,
                (relative_path, json.dumps(record))
            )

        log.info(f"Loaded {len(records)} task records from {relative_path}")
        return len(records)

    except Exception as e:
        log.error(f"Failed to load {relative_path}: {e}")
        return None


def load_workers_file(cursor, file_path, relative_path):
    """Loads workers.json — payload is a plain JSON array, NOT wrapped
    in a {"tasks": [...]} envelope. This is a single static file, not
    paginated, so it's loaded whole in one pass."""
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            payload = json.load(f)

        records = payload if isinstance(payload, list) else payload.get("data", [])

        if not records:
            log.info(f"No workers found in {relative_path}, skipping.")
            return 0

        for record in records:
            cursor.execute(
                """
                INSERT INTO bronze.onfleet_workers (source_file, raw_data)
                VALUES (%s, %s)
                """,
                (relative_path, json.dumps(record))
            )

        log.info(f"Loaded {len(records)} worker records from {relative_path}")
        return len(records)

    except Exception as e:
        log.error(f"Failed to load {relative_path}: {e}")
        return None


def process_file(cur, conn, file_path, relative_path, loader_fn):
    """Shared idempotency wrapper: skip if already processed, otherwise
    load and mark, committing or rolling back as appropriate."""
    if is_file_processed(cur, relative_path):
        log.info(f"Already processed: {relative_path}, skipping.")
        return

    record_count = loader_fn(cur, file_path, relative_path)

    if record_count is not None:
        mark_file_processed(cur, relative_path, record_count)
        conn.commit()
    else:
        conn.rollback()


def run():
    conn = get_connection()
    conn.autocommit = False

    try:
        with conn.cursor() as cur:
            ensure_bronze_tables(cur)
            conn.commit()

            for subfolder in sorted(SOURCE_FOLDER.iterdir()):
                if not subfolder.is_dir():
                    continue

                if subfolder.name == WORKERS_FOLDER_NAME:
                    # workers/ holds a single static file, not paginated,
                    # not a month folder — handle it on its own
                    for worker_file in sorted(subfolder.glob("*.json")):
                        relative_path = f"{subfolder.name}/{worker_file.name}"
                        process_file(cur, conn, worker_file, relative_path, load_workers_file)
                    continue

                # Everything else is a month folder (2025_01, 2025_02, ...)
                # full of paginated task files
                for page_file in sorted(subfolder.glob("*.json")):
                    relative_path = f"{subfolder.name}/{page_file.name}"
                    process_file(cur, conn, page_file, relative_path, load_task_file)

    except Exception as e:
        log.error(f"Fatal error: {e}")
        conn.rollback()
    finally:
        conn.close()


if __name__ == "__main__":
    run()