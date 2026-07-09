-- =============================================================================
-- analysis: explore_samsara_driver_summary.sql
-- purpose:  Unpack raw JSONB from bronze.samsara_driver_summary into readable
--           columns for exploratory review before writing the silver model.
--
-- layer:    bronze (read only — no data is created or modified)
-- schema:   bronze
-- source:   bronze.samsara_driver_summary (loaded by loaders/load_samsara.py)
--
-- usage:    Run via dbt Power User preview or psql session.
--           Not materialized — analysis files never create database objects.
-- =============================================================================

SELECT
    -- metadata columns added by the loader
    id                                          AS bronze_row_id,
    ingest_timestamp                            AS bronze_ingest_timestamp,
    source_file                                 AS bronze_source_file,

    -- driver
    raw_data ->> 'driverId'                     AS driver_id,
    raw_data ->> 'driverName'                   AS driver_name,

    -- location
    raw_data ->> '_city'                        AS city,

    -- driving summary
    (raw_data ->> 'totalTrips')::int            AS total_trips,
    (raw_data ->> 'safetyScore')::numeric       AS safety_score,

    -- behaviour metrics
    (raw_data ->> 'speedingCount')::int         AS speeding_count,
    (raw_data ->> 'harshAccelCount')::int       AS harsh_accel_count,
    (raw_data ->> 'harshBrakingCount')::int     AS harsh_braking_count,

    -- driving time
    (raw_data ->> 'totalIdleTimeMs')::bigint    AS total_idle_time_ms,
    (raw_data ->> 'totalDriveTimeMs')::bigint   AS total_drive_time_ms,

    -- distance
    (raw_data ->> 'totalDistanceMeters')::bigint AS total_distance_meters,

    -- HOS violations
    raw_data -> 'hosViolations'                 AS hos_violations,

    -- raw JSON
    raw_data

FROM bronze.samsara_driver_summary

ORDER BY ingest_timestamp DESC, bronze_row_id DESC;


RAW DATA:
{
  "_city": "albuquerque",
  "driverId": "20000046",
  "driverName": "Michael Brown",
  "totalTrips": 111,
  "safetyScore": 79.9,
  "hosViolations": [],
  "speedingCount": 6,
  "harshAccelCount": 8,
  "totalIdleTimeMs": 464948390,
  "totalDriveTimeMs": 2778721177,
  "harshBrakingCount": 6,
  "totalDistanceMeters": 27015345
}