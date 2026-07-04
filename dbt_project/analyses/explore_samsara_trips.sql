-- =============================================================================
-- analysis: explore_samsara_trips.sql
-- purpose:  Unpack raw JSONB from bronze.samsara_trips into readable
--           columns for exploratory review before writing the silver model.
--
-- layer:    bronze (read only, no data is created or modified)
-- schema:   bronze
-- source:   bronze.samsara_trips (loaded by loaders/load_samsara.py)
--
-- note:     vehicleId and driverId are FLAT fields on the trip record —
--           there is no nested 'vehicle' or 'driver' object here. Names
--           are NOT present on trip records at all (matches the real
--           Samsara API); resolve vehicle_name via bronze.samsara_vehicles
--           and driver_name via bronze.samsara_driver_summary, joining on
--           these IDs.
--
-- usage:    Run via dbt Power User preview or psql session.
--           Not materialized, analysis files never create database objects.
-- =============================================================================

select
    -- metadata columns added by the loader
    id                                              as bronze_row_id,
    ingest_timestamp                                as bronze_ingest_timestamp,
    source_file                                     as bronze_source_file,

    -- core trip identifiers
    raw_data ->> 'id'                               as trip_id,

    -- vehicle / driver — flat fields, no nested object, no name here
    raw_data ->> 'vehicleId'                        as vehicle_id,
    raw_data ->> 'driverId'                         as driver_id,   -- null on ~5% of trips (no driver login) — expected, see QUIRK 4

    -- timing
    (raw_data ->> 'startMs')::bigint / 1000         as start_epoch,
    (raw_data ->> 'endMs')::bigint / 1000           as end_epoch,
    to_timestamp((raw_data ->> 'startMs')::bigint / 1000) as started_at,
    to_timestamp((raw_data ->> 'endMs')::bigint / 1000)   as ended_at,

    -- distance and fuel
    (raw_data ->> 'distanceMeters')::numeric        as distance_meters,
    (raw_data ->> 'fuelConsumedMl')::numeric        as fuel_consumed_ml,

    -- raw data for reference
    raw_data

from bronze.samsara_trips

order by ingest_timestamp desc, bronze_row_id desc