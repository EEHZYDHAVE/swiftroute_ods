-- =============================================================================
-- analysis: explore_samsara_vehicles.sql
-- purpose:  Unpack raw JSONB from bronze.samsara_vehicles into readable
--           columns for exploratory review before writing the silver model.
--
-- layer:    bronze (read only — no data is created or modified)
-- schema:   bronze
-- source:   bronze.samsara_vehicles (loaded by loaders/load_samsara.py)
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
    raw_data ->> 'id'                                   as vehicle_id,
    raw_data ->> 'name'                                 as vehicle_name,

    -- vehicle details
    raw_data ->> 'make'                                 as make,
    raw_data ->> 'model'                                as model,
    raw_data ->> 'year'                                 as year,
    raw_data ->> 'vin'                                  as vin,
    raw_data ->> 'licensePlate'                         as license_plate,

    -- assignment
    raw_data ->> 'serial'                               as serial_number,
    raw_data ->> 'fuelType'                             as fuel_type,

    -- raw data for reference
    raw_data

from bronze.samsara_vehicles

order by ingest_timestamp desc, bronze_row_id desc