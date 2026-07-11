-- ============================================================
-- model:        silver_samsara_driver_summary
-- layer:        silver
-- source:       {{ source('bronze', 'samsara_driver_summary') }}
-- loaded_by:    loaders/load_samsara.py
-- description:  Cleaned and standardised driver summary records
--               from Samsara. Each record represents cumulative
--               fleet performance metrics for one driver across
--               the full simulation period.
--
-- key facts:
--   - driverId retained as driver_source_id. Surrogate key
--     drs_sk generated.
--   - driverId links to silver_samsara_trips on driver_id.
--   - driver_name used for cross-system joins to
--     silver_gusto_employees and silver_onfleet_workers
--     where UUID mapping is unavailable.
--   - hosViolations retained as JSONB (array, may be empty).
--   - Durations stored as milliseconds in source. Converted
--     to hours here for human readability.
--   - Distance stored as meters in source. Converted to
--     kilometres here for human readability.
--   - All empty strings to NULL.
--
-- incremental:  Upserts on MD5 of full row (record_hash_key).
--               Safe to re-run, existing records update.
--
-- depends_on:   bronze.samsara_driver_summary
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
    FROM {{ source('bronze', 'samsara_driver_summary') }}

    {% if is_incremental() %}
    WHERE ingest_timestamp > (
        SELECT MAX(silver_loaded_at) FROM {{ this }}
    )
    {% endif %}

),

-- ============================================================
-- SECTION 2: UNPACK
-- All field names verified against raw data samples.
-- ============================================================
unpacked AS (

    SELECT
        -- natural key
        raw_data ->> 'driverId'                                     AS driver_source_id,
        raw_data ->> 'driverName'                                   AS driver_name,

        -- location
        raw_data ->> '_city'                                        AS city_raw,

        -- driving summary
        (raw_data ->> 'totalTrips')::INT                            AS total_trips,
        (raw_data ->> 'safetyScore')::NUMERIC                       AS safety_score,

        -- behaviour metrics
        (raw_data ->> 'speedingCount')::INT                         AS speeding_count,
        (raw_data ->> 'harshAccelCount')::INT                       AS harsh_accel_count,
        (raw_data ->> 'harshBrakingCount')::INT                     AS harsh_braking_count,

        -- driving time (milliseconds)
        (raw_data ->> 'totalIdleTimeMs')::BIGINT                    AS total_idle_time_ms,
        (raw_data ->> 'totalDriveTimeMs')::BIGINT                   AS total_drive_time_ms,

        -- distance (meters)
        (raw_data ->> 'totalDistanceMeters')::BIGINT                AS total_distance_meters,

        -- HOS violations (array, may be empty)
        raw_data -> 'hosViolations'                                 AS hos_violations_raw,

        bronze_ingest_timestamp

    FROM source

),

-- ============================================================
-- SECTION 3: CLEAN
-- ============================================================
cleaned AS (

    SELECT
        driver_source_id,
        NULLIF(TRIM(driver_name), '')                               AS driver_name,
        INITCAP(NULLIF(TRIM(city_raw), ''))                         AS city,
        total_trips,
        safety_score,
        speeding_count,
        harsh_accel_count,
        harsh_braking_count,
        total_idle_time_ms,
        total_drive_time_ms,
        total_distance_meters,
        hos_violations_raw,
        bronze_ingest_timestamp

    FROM unpacked

),

-- ============================================================
-- SECTION 4: DERIVE
-- ============================================================
derived AS (

    SELECT
        *,

        -- Derived: total distance in kilometres
        ROUND(total_distance_meters / 1000.0, 2)                    AS total_distance_km,

        -- Derived: total drive time in hours
        ROUND(total_drive_time_ms / 3600000.0, 2)                   AS total_drive_time_hours,

        -- Derived: total idle time in hours
        ROUND(total_idle_time_ms / 3600000.0, 2)                    AS total_idle_time_hours,

        -- Derived: idle percentage of total drive time
        -- Pipeline-safe: NULL-safe, avoids division by zero
        CASE
            WHEN total_drive_time_ms IS NOT NULL
            AND total_drive_time_ms > 0
            AND total_idle_time_ms IS NOT NULL
            THEN ROUND(
                (total_idle_time_ms::NUMERIC / total_drive_time_ms) * 100
            , 1)
            ELSE NULL
        END                                                         AS idle_pct,

        -- Derived: average distance per trip in km
        CASE
            WHEN total_trips IS NOT NULL
            AND total_trips > 0
            AND total_distance_meters IS NOT NULL
            THEN ROUND(
                (total_distance_meters / 1000.0) / total_trips
            , 2)
            ELSE NULL
        END                                                         AS avg_distance_per_trip_km,

        -- Derived: safety event total count
        -- (sum of all behaviour incidents)
        COALESCE(speeding_count, 0) +
        COALESCE(harsh_accel_count, 0) +
        COALESCE(harsh_braking_count, 0)                            AS total_safety_incidents,

        -- Derived: safety score band for reporting
        CASE
            WHEN safety_score >= 90 THEN 'Excellent'
            WHEN safety_score >= 75 THEN 'Good'
            WHEN safety_score >= 60 THEN 'Fair'
            WHEN safety_score IS NOT NULL THEN 'Poor'
            ELSE NULL
        END                                                         AS safety_score_band,

        -- Derived: HOS violation count
        CASE
            WHEN hos_violations_raw IS NOT NULL
            THEN JSONB_ARRAY_LENGTH(hos_violations_raw)
            ELSE 0
        END                                                         AS hos_violation_count,

        -- Derived: has HOS violations flag
        CASE
            WHEN hos_violations_raw IS NOT NULL
            AND JSONB_ARRAY_LENGTH(hos_violations_raw) > 0
            THEN TRUE
            ELSE FALSE
        END                                                         AS has_hos_violations

    FROM cleaned

),

-- ============================================================
-- SECTION 5: SURROGATE KEY + SILVER METADATA
-- drs_sk: human-readable surrogate (drs_00001, drs_00002 ...)
-- record_hash_key: MD5 of full row for incremental upserts
-- ============================================================
final AS (

    SELECT
        -- -------------------------------------------------------
        -- surrogate key
        -- -------------------------------------------------------
        'drs_' || LPAD(
            ROW_NUMBER() OVER (ORDER BY driver_source_id)::TEXT
        , 5, '0')                                                   AS drs_sk,

        -- -------------------------------------------------------
        -- natural key
        -- -------------------------------------------------------
        driver_source_id,

        -- -------------------------------------------------------
        -- dbt incremental unique key
        -- -------------------------------------------------------
        MD5(
            COALESCE(driver_source_id, '')          ||
            COALESCE(driver_name, '')               ||
            COALESCE(total_trips::TEXT, '')         ||
            COALESCE(safety_score::TEXT, '')        ||
            COALESCE(total_distance_meters::TEXT, '')
        )                                                           AS record_hash_key,

        -- -------------------------------------------------------
        -- driver identity
        -- -------------------------------------------------------
        driver_name,
        city,

        -- -------------------------------------------------------
        -- trip summary
        -- -------------------------------------------------------
        total_trips,
        avg_distance_per_trip_km,

        -- -------------------------------------------------------
        -- distance
        -- -------------------------------------------------------
        total_distance_meters,
        total_distance_km,

        -- -------------------------------------------------------
        -- time
        -- -------------------------------------------------------
        total_drive_time_ms,
        total_drive_time_hours,
        total_idle_time_ms,
        total_idle_time_hours,
        idle_pct,

        -- -------------------------------------------------------
        -- safety
        -- -------------------------------------------------------
        safety_score,
        safety_score_band,
        total_safety_incidents,
        speeding_count,
        harsh_accel_count,
        harsh_braking_count,
        has_hos_violations,
        hos_violation_count,
        hos_violations_raw,

        -- -------------------------------------------------------
        -- silver metadata
        -- -------------------------------------------------------
        NOW()                                                       AS silver_loaded_at,
        'silver_samsara_driver_summary'                             AS silver_source_model

    FROM derived

)

SELECT * FROM final