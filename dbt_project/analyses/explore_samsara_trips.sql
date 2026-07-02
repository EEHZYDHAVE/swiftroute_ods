-- =============================================================================
-- analysis: explore_samsara_trips.sql
-- purpose:  Unpack raw JSONB from bronze.samsara_trips into readable
--           columns for exploratory review before writing the silver model.
--
-- layer:    bronze (read only, no data is created or modified)
-- schema:   bronze
-- source:   bronze.samsara_trips (loaded by loaders/load_samsara.py)
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

    -- vehicle
    raw_data -> 'vehicle' ->> 'id'                  as vehicle_id,
    raw_data -> 'vehicle' ->> 'name'                as vehicle_name,

    -- driver
    raw_data -> 'driver' ->> 'id'                   as driver_id,
    raw_data -> 'driver' ->> 'name'                 as driver_name,

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