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

SELECT
    -- metadata columns added by the loader
    id                                                  AS bronze_row_id,
    ingest_timestamp                                    AS bronze_ingest_timestamp,
    source_file                                         AS bronze_source_file,

    -- core trip identifiers
    raw_data ->> 'id'                                   AS trip_id,

    -- vehicle / driver
    raw_data ->> 'vehicleId'                            AS vehicle_id,
    raw_data ->> 'driverId'                             AS driver_id,

    -- timestamps
    (raw_data ->> 'startMs')::bigint                    AS start_ms,
    (raw_data ->> 'endMs')::bigint                      AS end_ms,
    to_timestamp((raw_data ->> 'startMs')::bigint / 1000.0) AS started_at,
    to_timestamp((raw_data ->> 'endMs')::bigint / 1000.0)   AS ended_at,

    -- duration
    (raw_data ->> 'durationMs')::bigint                 AS duration_ms,
    (raw_data ->> 'drivingDurationMs')::bigint          AS driving_duration_ms,
    (raw_data ->> 'idlingDurationMs')::bigint           AS idling_duration_ms,

    -- trip metrics
    (raw_data ->> 'distanceMeters')::numeric            AS distance_meters,
    (raw_data ->> 'fuelConsumedMl')::numeric            AS fuel_consumed_ml,
    (raw_data ->> 'fuelConsumedGallons')::numeric       AS fuel_consumed_gallons,
    (raw_data ->> 'averageSpeedMph')::numeric           AS average_speed_mph,
    (raw_data ->> 'maxSpeedMph')::numeric               AS max_speed_mph,

    -- start location
    raw_data -> 'startCoords' ->> 'latitude'            AS start_latitude,
    raw_data -> 'startCoords' ->> 'longitude'           AS start_longitude,
    raw_data ->> 'startAddress'                         AS start_address,

    -- end location
    raw_data -> 'endCoords' ->> 'latitude'              AS end_latitude,
    raw_data -> 'endCoords' ->> 'longitude'             AS end_longitude,
    raw_data ->> 'endAddress'                           AS end_address,

    -- safety events
    raw_data -> 'safetyEvents'                          AS safety_events,

    -- raw JSON
    raw_data

FROM bronze.samsara_trips

ORDER BY ingest_timestamp DESC, bronze_row_id DESC;