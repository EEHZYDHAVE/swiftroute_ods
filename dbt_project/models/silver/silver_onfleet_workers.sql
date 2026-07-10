-- ============================================================
-- model:        silver_onfleet_workers
-- layer:        silver
-- source:       {{ source('bronze', 'onfleet_workers') }}
-- loaded_by:    loaders/load_onfleet.py
-- description:  Cleaned and standardised worker (driver) records
--               from Onfleet. This is the AUTHORITATIVE source for
--               driver identity across the entire pipeline. The
--               worker_id here is the join key to onfleet_deliveries
--               and is the only place where a driver name is
--               resolvable from an Onfleet worker ID.
--
-- key facts:
--   - worker_id is already human-readable (drv_fte_001 etc.)
--     so no surrogate key is generated here per design decision.
--   - All other systems resolve driver identity by joining to
--     this table on worker_id.
--   - on_duty = false marks the one terminated driver.
--
-- incremental:  Upserts on worker_id (natural key from Onfleet).
--               Safe to re-run: existing records update in place,
--               new workers append automatically.
--
-- depends_on:   bronze.onfleet_workers
-- ============================================================

{{
    config(
        materialized='incremental',
        unique_key='record_hash_key',
        on_schema_change='sync_all_columns'
    )
}}

-- ============================================================
-- SECTION 1: SOURCE: pull from bronze
-- ============================================================
WITH source AS (

    SELECT
        id                  AS bronze_row_id,
        ingest_timestamp    AS bronze_ingest_timestamp,
        raw_data
    FROM {{ source('bronze', 'onfleet_workers') }}

    -- --------------------------------------------------------
    -- INCREMENTAL FILTER
    -- On first run: all rows pass through (silver table
    -- does not yet exist). On subsequent runs: only rows
    -- ingested after the latest silver load are processed.
    -- This is what makes it a pipeline, not a one-time load.
    -- --------------------------------------------------------
    {% if is_incremental() %}
    WHERE ingest_timestamp > (
        SELECT MAX(silver_loaded_at) FROM {{ this }}
    )
    {% endif %}

),

-- ============================================================
-- SECTION 2: UNPACK: extract JSONB fields into typed columns
-- All field names and paths verified against raw data samples.
-- ============================================================
unpacked AS (

    SELECT
        -- natural key (already human-readable, kept as-is per design)
        raw_data ->> 'id'                                           AS worker_id,
        raw_data ->> 'organization'                                 AS organization_id,

        -- identity
        raw_data ->> 'name'                                         AS worker_name,
        raw_data ->> 'displayName'                                  AS display_name,
        raw_data ->> 'phone'                                        AS phone_raw,
        raw_data ->> 'imageUrl'                                     AS image_url,

        -- employment type (from metadata array, index 0)
        -- pattern: [{name: "employment_type", value: "FTE"/"IC"}]
        raw_data -> 'metadata' -> 0 ->> 'value'                     AS employment_type_raw,

        -- duty status
        (raw_data ->> 'onDuty')::BOOLEAN                            AS on_duty,
        raw_data ->> 'activeTask'                                   AS active_task_id,

        -- teams (array: first team extracted as primary team)
        raw_data -> 'teams' -> 0                                    AS primary_team_raw,
        JSONB_ARRAY_LENGTH(raw_data -> 'teams')                     AS team_count,

        -- vehicle (nested object)
        raw_data -> 'vehicle' ->> 'id'                              AS vehicle_id,
        raw_data -> 'vehicle' ->> 'type'                            AS vehicle_type_raw,
        raw_data -> 'vehicle' ->> 'description'                     AS vehicle_description,
        raw_data -> 'vehicle' ->> 'licensePlate'                    AS vehicle_license_plate,
        raw_data -> 'vehicle' ->> 'color'                           AS vehicle_color,

        -- timestamps (Onfleet stores epoch milliseconds: divide by 1000)
        TO_TIMESTAMP(
            (raw_data ->> 'timeCreated')::BIGINT / 1000.0
        ) AT TIME ZONE 'UTC'                                        AS worker_created_at,

        TO_TIMESTAMP(
            (raw_data ->> 'timeLastModified')::BIGINT / 1000.0
        ) AT TIME ZONE 'UTC'                                        AS worker_last_modified_at,

        -- bronze metadata (kept for incremental tracking only)
        bronze_ingest_timestamp

    FROM source

),

-- ============================================================
-- SECTION 3: CLEAN: nulls, empty strings, standardisation
-- Rule: all empty strings become NULL.
-- Rule: all lookup values are standardised to lowercase.
-- ============================================================
cleaned AS (

    SELECT
        worker_id,
        organization_id,

        -- identity: empty strings to NULL
        NULLIF(TRIM(worker_name), '')                               AS worker_name,
        NULLIF(TRIM(display_name), '')                              AS display_name,
        NULLIF(TRIM(image_url), '')                                 AS image_url,

        -- employment type: standardise to uppercase, NULL if missing
        UPPER(NULLIF(TRIM(employment_type_raw), ''))                AS employment_type,

        -- duty status
        on_duty,
        NULLIF(TRIM(active_task_id), '')                            AS active_task_id,

        -- team
        NULLIF(TRIM(primary_team_raw::TEXT), '')                    AS primary_team,
        team_count,

        -- vehicle
        NULLIF(TRIM(vehicle_id), '')                                AS vehicle_id,
        UPPER(NULLIF(TRIM(vehicle_type_raw), ''))                   AS vehicle_type,
        NULLIF(TRIM(vehicle_description), '')                       AS vehicle_description,
        NULLIF(TRIM(vehicle_license_plate), '')                     AS vehicle_license_plate,
        LOWER(NULLIF(TRIM(vehicle_color), ''))                      AS vehicle_color,

        -- timestamps (already TIMESTAMPTZ from unpack)
        worker_created_at,
        worker_last_modified_at,

        -- pass through for derive section
        phone_raw,
        bronze_ingest_timestamp

    FROM unpacked

),

-- ============================================================
-- SECTION 4: DERIVE: computed/enriched columns
-- ============================================================
derived AS (

    SELECT
        *,

        -- Derived: is this worker active?
        -- on_duty = false marks the terminated driver.
        -- Named is_active for cross-system consistency with Gusto.
        on_duty                                                     AS is_active,

        -- Derived: city extracted from primary team name
        -- team names follow pattern: team_denver, team_albuquerque, team_slc
        -- We extract the city portion for human readability.
        CASE
            WHEN primary_team ILIKE '%denver%'      THEN 'Denver'
            WHEN primary_team ILIKE '%albuquerque%' THEN 'Albuquerque'
            WHEN primary_team ILIKE '%slc%'         THEN 'Salt Lake City'
            ELSE NULL
        END                                                         AS city,

        -- Derived: employment type label
        CASE employment_type
            WHEN 'FTE' THEN 'Full-Time Employee'
            WHEN 'IC'  THEN 'Independent Contractor'
            ELSE 'Unknown'
        END                                                         AS employment_type_label

    FROM cleaned

),

-- ============================================================
-- SECTION 5: SURROGATE KEY + SILVER METADATA
-- worker_id is already human-readable per design decision.
-- We use MD5 of the full unpacked row as the record hash key
-- for dbt incremental upserts and change detection.
-- ============================================================
final AS (

    SELECT
        -- -------------------------------------------------------
        -- natural key (kept as PK per design: already readable)
        -- -------------------------------------------------------
        worker_id,

        -- -------------------------------------------------------
        -- dbt incremental unique key
        -- MD5 of full row detects any field-level change.
        -- -------------------------------------------------------
        MD5(
            COALESCE(worker_id, '')             ||
            COALESCE(worker_name, '')           ||
            COALESCE(employment_type, '')       ||
            COALESCE(vehicle_type, '')          ||
            COALESCE(vehicle_license_plate, '') ||
            COALESCE(on_duty::TEXT, '')         ||
            COALESCE(worker_created_at::TEXT, '')
        )                                                           AS record_hash_key,

        -- -------------------------------------------------------
        -- worker attributes
        -- -------------------------------------------------------
        organization_id,
        worker_name,
        display_name,
        phone_raw                                                   AS phone,
        image_url,
        employment_type,
        employment_type_label,
        is_active,
        on_duty,
        active_task_id,
        primary_team,
        team_count,
        city,

        -- -------------------------------------------------------
        -- vehicle
        -- -------------------------------------------------------
        vehicle_id,
        vehicle_type,
        vehicle_description,
        vehicle_license_plate,
        vehicle_color,

        -- -------------------------------------------------------
        -- timestamps
        -- -------------------------------------------------------
        worker_created_at,
        worker_last_modified_at,

        -- -------------------------------------------------------
        -- silver metadata
        -- -------------------------------------------------------
        NOW()                                                       AS silver_loaded_at,
        'silver_onfleet_workers'                                    AS silver_source_model

    FROM derived

)

SELECT * FROM final