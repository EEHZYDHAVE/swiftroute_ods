-- ============================================================
-- model:        silver_samsara_trips
-- layer:        silver
-- source:       {{ source('bronze', 'samsara_trips') }}
-- loaded_by:    loaders/load_samsara.py
-- description:  Cleaned and standardised trip records from
--               Samsara fleet telematics. Each record represents
--               one vehicle trip driven by one driver.
--
-- key facts:
--   - trip id retained as trip_source_id. Surrogate key
--     trp_sk generated.
--   - vehicleId and driverId are FLAT fields on trip records.
--     There are no nested vehicle or driver objects here.
--     This matches the real Samsara API behaviour.
--   - Driver names are NOT present on trip records. Resolve
--     driver name via silver_samsara_driver_summary joining
--     on driver_id.
--   - Vehicle names are NOT present on trip records. Resolve
--     vehicle name via silver_samsara_vehicles joining on
--     vehicle_id.
--   - Timestamps stored as epoch milliseconds in source.
--     Converted to TIMESTAMPTZ (UTC) here.
--   - A small number of trips may fall in early July 2025
--     (2025_07 folder). This is not a data quality error,
--     it reflects late-June deliveries completing past
--     midnight on June 30. Pipeline does not hardcode
--     month ranges to handle this correctly.
--   - safetyEvents retained as JSONB (array, may be empty).
--   - All empty strings to NULL.
--
-- incremental:  Upserts on MD5 of full row (record_hash_key).
--               Safe to re-run, existing records update.
--
-- depends_on:   bronze.samsara_trips
--               silver.silver_samsara_vehicles
-- ============================================================

{{
    config(
        materialized='incremental',
        unique_key='record_hash_key',
        on_schema_change='sync_all_columns'
    )
}}

-- ============================================================
-- SECTION 1: SOURCE
-- ============================================================
WITH source AS (

    SELECT
        id                  AS bronze_row_id,
        ingest_timestamp    AS bronze_ingest_timestamp,
        raw_data
    FROM {{ source('bronze', 'samsara_trips') }}

    {% if is_incremental() %}
    WHERE ingest_timestamp > (
        SELECT MAX(silver_loaded_at) FROM {{ this }}
    )
    {% endif %}

),

-- ============================================================
-- SECTION 2: UNPACK
-- All field names verified against raw data samples.
-- Epoch milliseconds divided by 1000.0 for TIMESTAMPTZ
-- conversion. Using 1000.0 (not 1000) ensures numeric
-- division, not integer division.
-- ============================================================
unpacked AS (

    SELECT
        -- natural key
        raw_data ->> 'id'                                           AS trip_source_id,

        -- vehicle and driver (flat fields, no nested objects)
        raw_data ->> 'vehicleId'                                    AS vehicle_id,
        raw_data ->> 'driverId'                                     AS driver_id,

        -- timestamps (epoch milliseconds to TIMESTAMPTZ UTC)
        (raw_data ->> 'startMs')::BIGINT                            AS start_ms,
        (raw_data ->> 'endMs')::BIGINT                              AS end_ms,
        TO_TIMESTAMP(
            (raw_data ->> 'startMs')::BIGINT / 1000.0
        ) AT TIME ZONE 'UTC'                                        AS started_at,
        TO_TIMESTAMP(
            (raw_data ->> 'endMs')::BIGINT / 1000.0
        ) AT TIME ZONE 'UTC'                                        AS ended_at,

        -- duration (milliseconds)
        (raw_data ->> 'durationMs')::BIGINT                         AS duration_ms,
        (raw_data ->> 'drivingDurationMs')::BIGINT                  AS driving_duration_ms,
        (raw_data ->> 'idlingDurationMs')::BIGINT                   AS idling_duration_ms,

        -- trip metrics
        (raw_data ->> 'distanceMeters')::NUMERIC                    AS distance_meters,
        (raw_data ->> 'fuelConsumedMl')::NUMERIC                    AS fuel_consumed_ml,
        (raw_data ->> 'fuelConsumedGallons')::NUMERIC               AS fuel_consumed_gallons,
        (raw_data ->> 'averageSpeedMph')::NUMERIC                   AS average_speed_mph,
        (raw_data ->> 'maxSpeedMph')::NUMERIC                       AS max_speed_mph,

        -- start location
        (raw_data -> 'startCoords' ->> 'latitude')::NUMERIC         AS start_latitude,
        (raw_data -> 'startCoords' ->> 'longitude')::NUMERIC        AS start_longitude,
        raw_data ->> 'startAddress'                                 AS start_address,

        -- end location
        (raw_data -> 'endCoords' ->> 'latitude')::NUMERIC           AS end_latitude,
        (raw_data -> 'endCoords' ->> 'longitude')::NUMERIC          AS end_longitude,
        raw_data ->> 'endAddress'                                   AS end_address,

        -- safety events (array, may be empty)
        raw_data -> 'safetyEvents'                                  AS safety_events_raw,

        bronze_ingest_timestamp

    FROM source

),

-- ============================================================
-- SECTION 3: CLEAN
-- ============================================================
cleaned AS (

    SELECT
        trip_source_id,
        NULLIF(TRIM(vehicle_id), '')                                AS vehicle_id,
        NULLIF(TRIM(driver_id), '')                                 AS driver_id,
        start_ms,
        end_ms,
        started_at,
        ended_at,
        duration_ms,
        driving_duration_ms,
        idling_duration_ms,
        distance_meters,
        fuel_consumed_ml,
        fuel_consumed_gallons,
        average_speed_mph,
        max_speed_mph,
        start_latitude,
        start_longitude,
        NULLIF(TRIM(start_address), '')                             AS start_address,
        end_latitude,
        end_longitude,
        NULLIF(TRIM(end_address), '')                               AS end_address,
        safety_events_raw,
        bronze_ingest_timestamp

    FROM unpacked

),

-- ============================================================
-- SECTION 4: DERIVE
-- ============================================================
derived AS (

    SELECT
        *,

        -- Derived: trip duration in minutes (human readable)
        CASE
            WHEN duration_ms IS NOT NULL
            THEN ROUND(duration_ms / 60000.0, 1)
            ELSE NULL
        END                                                         AS duration_minutes,

        -- Derived: driving duration in minutes
        CASE
            WHEN driving_duration_ms IS NOT NULL
            THEN ROUND(driving_duration_ms / 60000.0, 1)
            ELSE NULL
        END                                                         AS driving_duration_minutes,

        -- Derived: idling duration in minutes
        CASE
            WHEN idling_duration_ms IS NOT NULL
            THEN ROUND(idling_duration_ms / 60000.0, 1)
            ELSE NULL
        END                                                         AS idling_duration_minutes,

        -- Derived: distance in kilometres
        CASE
            WHEN distance_meters IS NOT NULL
            THEN ROUND(distance_meters / 1000.0, 2)
            ELSE NULL
        END                                                         AS distance_km,

        -- Derived: idling percentage of total trip duration
        -- Pipeline-safe: NULL-safe, avoids division by zero
        CASE
            WHEN duration_ms IS NOT NULL
            AND duration_ms > 0
            AND idling_duration_ms IS NOT NULL
            THEN ROUND(
                (idling_duration_ms::NUMERIC / duration_ms) * 100
            , 1)
            ELSE NULL
        END                                                         AS idling_pct,

        -- Derived: fuel efficiency (km per litre)
        -- fuelConsumedMl converted to litres (divide by 1000)
        CASE
            WHEN fuel_consumed_ml IS NOT NULL
            AND fuel_consumed_ml > 0
            AND distance_meters IS NOT NULL
            THEN ROUND(
                (distance_meters / 1000.0) / (fuel_consumed_ml / 1000.0)
            , 2)
            ELSE NULL
        END                                                         AS fuel_efficiency_km_per_litre,

        -- Derived: safety event count
        CASE
            WHEN safety_events_raw IS NOT NULL
            THEN JSONB_ARRAY_LENGTH(safety_events_raw)
            ELSE 0
        END                                                         AS safety_event_count,

        -- Derived: has safety events flag
        CASE
            WHEN safety_events_raw IS NOT NULL
            AND JSONB_ARRAY_LENGTH(safety_events_raw) > 0
            THEN TRUE
            ELSE FALSE
        END                                                         AS has_safety_events,

        -- Derived: trip date (for daily aggregations)
        started_at::DATE                                            AS trip_date

    FROM cleaned

),

-- ============================================================
-- SECTION 5: JOIN to silver_samsara_vehicles
-- LEFT JOIN: preserves trips where vehicle_id cannot be
-- resolved (edge case only).
-- ============================================================
with_vehicle AS (

    SELECT
        d.*,
        v.vehicle_sk,
        v.vehicle_name,
        v.make,
        v.model,
        v.vehicle_type,
        v.fuel_type,
        v.city                                                      AS vehicle_city
    FROM derived d
    LEFT JOIN {{ ref('silver_samsara_vehicles') }} v
        ON d.vehicle_id = v.vehicle_id

),

-- ============================================================
-- SECTION 6: SURROGATE KEY + SILVER METADATA
-- trp_sk: human-readable surrogate (trp_000001 ...)
-- record_hash_key: MD5 of full row for incremental upserts
-- ============================================================
final AS (

    SELECT
        -- -------------------------------------------------------
        -- surrogate key
        -- -------------------------------------------------------
        'trp_' || LPAD(
            ROW_NUMBER() OVER (
                ORDER BY started_at ASC, trip_source_id ASC
            )::TEXT
        , 6, '0')                                                   AS trp_sk,

        -- -------------------------------------------------------
        -- natural key
        -- -------------------------------------------------------
        trip_source_id,

        -- -------------------------------------------------------
        -- dbt incremental unique key
        -- -------------------------------------------------------
        MD5(
            COALESCE(trip_source_id, '')            ||
            COALESCE(vehicle_id, '')                ||
            COALESCE(driver_id, '')                 ||
            COALESCE(started_at::TEXT, '')          ||
            COALESCE(ended_at::TEXT, '')            ||
            COALESCE(distance_meters::TEXT, '')
        )                                                           AS record_hash_key,

        -- -------------------------------------------------------
        -- vehicle reference
        -- -------------------------------------------------------
        vehicle_id,
        vehicle_sk,
        vehicle_name,
        make,
        model,
        vehicle_type,
        fuel_type,
        vehicle_city,

        -- -------------------------------------------------------
        -- driver reference (name resolved via driver_summary)
        -- -------------------------------------------------------
        driver_id,

        -- -------------------------------------------------------
        -- timestamps
        -- -------------------------------------------------------
        started_at,
        ended_at,
        trip_date,

        -- -------------------------------------------------------
        -- duration
        -- -------------------------------------------------------
        duration_minutes,
        driving_duration_minutes,
        idling_duration_minutes,
        idling_pct,

        -- -------------------------------------------------------
        -- distance and fuel
        -- -------------------------------------------------------
        distance_meters,
        distance_km,
        fuel_consumed_ml,
        fuel_consumed_gallons,
        fuel_efficiency_km_per_litre,

        -- -------------------------------------------------------
        -- speed
        -- -------------------------------------------------------
        average_speed_mph,
        max_speed_mph,

        -- -------------------------------------------------------
        -- locations
        -- -------------------------------------------------------
        start_address,
        start_latitude,
        start_longitude,
        end_address,
        end_latitude,
        end_longitude,

        -- -------------------------------------------------------
        -- safety
        -- -------------------------------------------------------
        safety_event_count,
        has_safety_events,
        safety_events_raw,

        -- -------------------------------------------------------
        -- silver metadata
        -- -------------------------------------------------------
        NOW()                                                       AS silver_loaded_at,
        'silver_samsara_trips'                                      AS silver_source_model

    FROM with_vehicle

)

SELECT * FROM final