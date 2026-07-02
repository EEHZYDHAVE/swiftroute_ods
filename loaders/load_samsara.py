"""
loader: load_samsara.py
source system: Samsara (Fleet & Vehicle Telematics)
bronze tables: bronze.samsara_vehicles
               bronze.samsara_trips
               bronze.samsara_driver_summary

Reads from source_data/raw/samsara/:
- vehicles/vehicles.json — single file wrapped in 'data' envelope
- driver_summary/driver_summary.json — single file wrapped in 'data' envelope
- trips/{month}/trips_{vehicle_id}.json — one file per vehicle per month,
  wrapped in 'trips' envelope

Records are inserted as-is into the respective bronze tables as JSONB.
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

SOURCE_SYSTEM = "samsara"
SOURCE_FOLDER = Path("source_data/raw/samsara")


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
    for table in ["samsara_vehicles", "samsara_trips", "samsara_driver_summary"]:
        cursor.execute(f"""
            CREATE TABLE IF NOT EXISTS bronze.{table} (
                id               SERIAL PRIMARY KEY,
                ingest_timestamp TIMESTAMP NOT NULL DEFAULT NOW(),
                source_file      VARCHAR   NOT NULL,
                raw_data         JSONB     NOT NULL
            )
        """)


def load_data_envelope(cursor, file_path, relative_path, table):
    """For vehicles and driver_summary — wrapped in data envelope."""
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            payload = json.load(f)

        records = payload.get("data", [])

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


def load_trips(cursor, file_path, relative_path):
    """For trips — wrapped in trips envelope."""
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            payload = json.load(f)

        records = payload.get("trips", [])

        if not records:
            log.info(f"No trips in {relative_path}, skipping.")
            return 0

        for record in records:
            cursor.execute(
                "INSERT INTO bronze.samsara_trips (source_file, raw_data) VALUES (%s, %s)",
                (relative_path, json.dumps(record))
            )

        log.info(f"Loaded {len(records)} trips from {relative_path}")
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

            # vehicles
            vehicles_file = SOURCE_FOLDER / "vehicles" / "vehicles.json"
            relative_path = "vehicles/vehicles.json"
            if not is_file_processed(cur, relative_path):
                count = load_data_envelope(cur, vehicles_file, relative_path, "samsara_vehicles")
                if count is not None:
                    mark_file_processed(cur, relative_path, count)
                    conn.commit()
                else:
                    conn.rollback()

            # driver_summary
            summary_file = SOURCE_FOLDER / "driver_summary" / "driver_summary.json"
            relative_path = "driver_summary/driver_summary.json"
            if not is_file_processed(cur, relative_path):
                count = load_data_envelope(cur, summary_file, relative_path, "samsara_driver_summary")
                if count is not None:
                    mark_file_processed(cur, relative_path, count)
                    conn.commit()
                else:
                    conn.rollback()

            # trips
            trips_folder = SOURCE_FOLDER / "trips"
            for month_folder in sorted(trips_folder.iterdir()):
                if not month_folder.is_dir():
                    continue
                for trip_file in sorted(month_folder.glob("*.json")):
                    relative_path = f"trips/{month_folder.name}/{trip_file.name}"
                    if is_file_processed(cur, relative_path):
                        log.info(f"Already processed: {relative_path}, skipping.")
                        continue
                    count = load_trips(cur, trip_file, relative_path)
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