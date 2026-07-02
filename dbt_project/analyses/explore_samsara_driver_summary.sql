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

select
    -- metadata columns added by the loader
    id                                                  as bronze_row_id,
    ingest_timestamp                                    as bronze_ingest_timestamp,
    source_file                                         as bronze_source_file,

    -- core identifiers
    raw_data ->> 'driverId'                             as driver_id,
    raw_data ->> 'driverName'                           as driver_name,

    -- summary metrics
    (raw_data ->> 'totalDistanceMeters')::numeric       as total_distance_meters,
    (raw_data ->> 'totalDriveMs')::bigint / 1000        as total_drive_seconds,
    (raw_data ->> 'totalOnDutyMs')::bigint / 1000       as total_on_duty_seconds,

    -- safety scores
    (raw_data ->> 'safetyScore')::numeric               as safety_score,
    (raw_data ->> 'harshAccelCount')::int               as harsh_accel_count,
    (raw_data ->> 'harshBrakeCount')::int               as harsh_brake_count,
    (raw_data ->> 'harshTurnCount')::int                as harsh_turn_count,
    (raw_data ->> 'overspeedCount')::int                as overspeed_count,

    -- raw data for reference
    raw_data

from bronze.samsara_driver_summary

order by ingest_timestamp desc, bronze_row_id desc