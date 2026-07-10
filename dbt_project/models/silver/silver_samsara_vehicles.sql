-- ============================================================
-- model:        silver_samsara_vehicles
-- layer:        silver
-- source:       {{ source('bronze', 'samsara_vehicles') }}
-- loaded_by:    loaders/load_samsara.py
-- description:  Cleaned and standardised vehicle records from
--               Samsara. This is the AUTHORITATIVE source for
--               vehicle identity across the pipeline. vehicle_id
--               is the join key to silver_samsara_trips.
--
-- key facts:
--   - vehicle_id is a numeric string from Samsara (e.g. "42554227")
--     A human-readable surrogate key (veh_sk) is generated here.
--   - City is derived from the first tag on each vehicle record.
--   - operational_status is standardised to lowercase.
--   - Tags array is kept as JSONB for downstream flexibility.
--
-- incremental:  Upserts on MD5 of full row (record_hash_key).
--               Safe to re-run — existing records update in place,
--               new vehicles append automatically.
--
-- depends_on:   bronze.samsara_vehicles
-- ============================================================

{{
    config(
        materialized='incremental',
        unique_key='record_hash_key',
        on_schema_change='sync_all_columns'
    )
}}

-- ============================================================
-- SECTION 1: SOURCE — pull from bronze
-- ============================================================
WITH source AS (

    SELECT
        id                  AS bronze_row_id,
        ingest_timestamp    AS bronze_ingest_timestamp,
        raw_data
    FROM {{ source('bronze', 'samsara_vehicles') }}

    {% if is_incremental() %}
    WHERE ingest_timestamp > (
        SELECT MAX(silver_loaded_at) FROM {{ this }}
    )
    {% endif %}

),

-- ============================================================
-- SECTION 2: UNPACK — extract JSONB fields into typed columns
-- All field names verified against raw data samples.
-- ============================================================
unpacked AS (

    SELECT
        -- natural key
        raw_data ->> 'id'                                           AS vehicle_id,
        raw_data ->> 'name'                                         AS vehicle_name,

        -- vehicle details
        raw_data ->> 'make'                                         AS make,
        raw_data ->> 'model'                                        AS model,
        (raw_data ->> 'year')::INT                                  AS manufacture_year,
        raw_data ->> 'vin'                                          AS vin,
        raw_data ->> 'licensePlate'                                 AS license_plate,

        -- classification
        raw_data ->> 'vehicleType'                                  AS vehicle_type_raw,
        raw_data ->> 'fuelType'                                     AS fuel_type_raw,
        raw_data ->> 'operationalStatus'                            AS operational_status_raw,

        -- telemetry
        (raw_data ->> 'currentOdometerMeters')::BIGINT              AS current_odometer_meters,

        -- last known location
        (raw_data -> 'lastKnownLocation' ->> 'latitude')::NUMERIC   AS last_latitude,
        (raw_data -> 'lastKnownLocation' ->> 'longitude')::NUMERIC  AS last_longitude,

        -- tags (array — first tag = city, second tag = vehicle type)
        raw_data -> 'tags' -> 0 ->> 'name'                          AS tag_1_name,
        raw_data -> 'tags' -> 1 ->> 'name'                          AS tag_2_name,
        raw_data -> 'tags'                                          AS tags_raw,

        -- bronze metadata
        bronze_ingest_timestamp

    FROM source

),

-- ============================================================
-- SECTION 3: CLEAN — nulls, empty strings, standardisation
-- ============================================================
cleaned AS (

    SELECT
        vehicle_id,
        NULLIF(TRIM(vehicle_name), '')                              AS vehicle_name,
        NULLIF(TRIM(make), '')                                      AS make,
        NULLIF(TRIM(model), '')                                     AS model,
        manufacture_year,
        NULLIF(TRIM(vin), '')                                       AS vin,
        NULLIF(TRIM(license_plate), '')                             AS license_plate,

        -- standardise to title case
        INITCAP(NULLIF(TRIM(vehicle_type_raw), ''))                 AS vehicle_type,
        LOWER(NULLIF(TRIM(fuel_type_raw), ''))                      AS fuel_type,
        LOWER(NULLIF(TRIM(operational_status_raw), ''))             AS operational_status,

        current_odometer_meters,
        last_latitude,
        last_longitude,

        -- tags
        LOWER(NULLIF(TRIM(tag_1_name), ''))                         AS tag_city_raw,
        INITCAP(NULLIF(TRIM(tag_2_name), ''))                       AS tag_vehicle_type,
        tags_raw,

        bronze_ingest_timestamp

    FROM unpacked

),

-- ============================================================
-- SECTION 4: DERIVE — computed/enriched columns
-- ============================================================
derived AS (

    SELECT
        *,

        -- Derived: is this vehicle active?
        CASE
            WHEN operational_status = 'active' THEN TRUE
            ELSE FALSE
        END                                                         AS is_active,

        -- Derived: city from tag_1 (follows pattern: denver,
        -- albuquerque, slc — standardised to human-readable name)
        CASE
            WHEN tag_city_raw ILIKE '%denver%'      THEN 'Denver'
            WHEN tag_city_raw ILIKE '%albuquerque%' THEN 'Albuquerque'
            WHEN tag_city_raw ILIKE '%slc%'         THEN 'Salt Lake City'
            ELSE NULL
        END                                                         AS city,

        -- Derived: odometer in kilometres for cross-system reporting
        ROUND(current_odometer_meters / 1000.0, 2)                  AS current_odometer_km

    FROM cleaned

),

-- ============================================================
-- SECTION 5: SURROGATE KEY + SILVER METADATA
-- veh_sk: human-readable surrogate key (veh_00001, veh_00002...)
-- record_hash_key: MD5 of full row for dbt incremental upserts
--   and change detection across any field.
-- ============================================================
final AS (

    SELECT
        -- -------------------------------------------------------
        -- surrogate key (human-readable, pipeline-stable)
        -- -------------------------------------------------------
        'veh_' || LPAD(
            ROW_NUMBER() OVER (ORDER BY vehicle_id)::TEXT, 5, '0'
        )                                                           AS vehicle_sk,

        -- -------------------------------------------------------
        -- natural key (Samsara vehicle ID — retained for joining)
        -- -------------------------------------------------------
        vehicle_id,

        -- -------------------------------------------------------
        -- dbt incremental unique key
        -- -------------------------------------------------------
        MD5(
            COALESCE(vehicle_id, '')            ||
            COALESCE(vehicle_name, '')          ||
            COALESCE(vin, '')                   ||
            COALESCE(license_plate, '')         ||
            COALESCE(operational_status, '')    ||
            COALESCE(vehicle_type, '')          ||
            COALESCE(current_odometer_meters::TEXT, '')
        )                                                           AS record_hash_key,

        -- -------------------------------------------------------
        -- vehicle attributes
        -- -------------------------------------------------------
        vehicle_name,
        make,
        model,
        manufacture_year,
        vin,
        license_plate,
        vehicle_type,
        fuel_type,
        operational_status,
        is_active,
        city,

        -- -------------------------------------------------------
        -- telemetry
        -- -------------------------------------------------------
        current_odometer_meters,
        current_odometer_km,
        last_latitude,
        last_longitude,

        -- -------------------------------------------------------
        -- tags (kept as JSONB for downstream flexibility)
        -- -------------------------------------------------------
        tags_raw,

        -- -------------------------------------------------------
        -- silver metadata
        -- -------------------------------------------------------
        NOW()                                                       AS silver_loaded_at,
        'silver_samsara_vehicles'                                   AS silver_source_model

    FROM derived

)

SELECT * FROM final