-- ============================================================
-- model:        driver_id_map
-- layer:        gold_operations (ETL support, not star schema)
-- description:  Cross-system driver identity resolution table.
--               Maps onfleet_worker_id, gusto_uuid, and
--               samsara_driver_id to a single canonical
--               driver_key for use across all fact tables.
--
-- key facts:
--   - This table is NOT part of the star schema. It is an
--     ETL support table used only during fact table loading
--     to resolve driver identity across three source systems.
--   - Join key across systems is driver full name, since no
--     shared UUID exists between Onfleet, Gusto, and Samsara.
--   - canonical_driver_key = onfleet worker_id (already
--     human-readable, e.g. drv_fte_001). This is the single
--     authoritative driver identifier used in dim_driver and
--     all fact tables.
--   - is_active = FALSE marks the one terminated driver.
--     This is canonical across all three source systems.
--   - effective_from, effective_to support SCD2 patterns
--     in future if driver identity changes over time.
--
-- materialized: table (small, full rebuild each run is cheap,
--               always reflects current silver state)
--
-- depends_on:   silver.silver_onfleet_workers
--               silver.silver_gusto_employees
--               silver.silver_samsara_driver_summary
-- ============================================================

{{
    config(
        materialized='table',
        schema='gold_operations'
    )
}}

-- ============================================================
-- SECTION 1: BASE SETS
-- Pull the three driver rosters from silver. Each system has
-- different IDs but shares driver full name as the join key.
-- ============================================================
WITH onfleet_drivers AS (

    SELECT
        worker_id                                                   AS onfleet_worker_id,
        worker_name                                                 AS driver_name,
        employment_type,
        is_active
    FROM {{ ref('silver_onfleet_workers') }}

),

gusto_drivers AS (

    SELECT
        employee_source_id                                          AS gusto_uuid,
        full_name                                                   AS driver_name,
        is_active                                                   AS gusto_is_active
    FROM {{ ref('silver_gusto_employees') }}
    WHERE is_driver = TRUE

),

samsara_drivers AS (

    SELECT
        driver_source_id                                            AS samsara_driver_id,
        driver_name,
        safety_score
    FROM {{ ref('silver_samsara_driver_summary') }}

),

-- ============================================================
-- SECTION 2: RESOLVE CROSS-SYSTEM IDENTITY
-- Join on normalised full name (UPPER, TRIM) to handle minor
-- casing differences across systems. Pipeline-safe: name
-- normalisation is applied at join time, not hardcoded.
-- LEFT JOIN from Onfleet (authoritative) to Gusto and Samsara
-- so all Onfleet workers are preserved even if they do not
-- appear in the other systems.
-- ============================================================
resolved AS (

    SELECT
        o.onfleet_worker_id,
        g.gusto_uuid,
        s.samsara_driver_id,
        o.driver_name,
        o.employment_type,
        o.is_active

    FROM onfleet_drivers o

    LEFT JOIN gusto_drivers g
        ON UPPER(TRIM(o.driver_name)) = UPPER(TRIM(g.driver_name))

    LEFT JOIN samsara_drivers s
        ON UPPER(TRIM(o.driver_name)) = UPPER(TRIM(s.driver_name))

),

-- ============================================================
-- SECTION 3: FINAL
-- canonical_driver_key = onfleet_worker_id (authoritative,
-- already human-readable). All fact tables use this key.
-- effective_from and effective_to are set conservatively
-- for SCD2 readiness. is_active reflects the canonical
-- termination status shared across all source systems.
-- ============================================================
final AS (

    SELECT
        -- -------------------------------------------------------
        -- canonical driver key (used in all fact tables)
        -- -------------------------------------------------------
        onfleet_worker_id                                           AS canonical_driver_key,

        -- -------------------------------------------------------
        -- source system IDs (kept for traceability)
        -- -------------------------------------------------------
        onfleet_worker_id,
        gusto_uuid,
        samsara_driver_id,

        -- -------------------------------------------------------
        -- driver attributes
        -- -------------------------------------------------------
        driver_name,
        employment_type,
        is_active,

        -- -------------------------------------------------------
        -- SCD2 readiness fields
        -- effective_from: set to pipeline run date for now.
        -- effective_to: NULL means currently active record.
        -- Pipeline-safe: these support future SCD2 expansion
        -- without requiring a schema change.
        -- -------------------------------------------------------
        CURRENT_DATE                                                AS effective_from,
        CASE
            WHEN is_active = FALSE THEN CURRENT_DATE
            ELSE NULL
        END                                                         AS effective_to,
        is_active                                                   AS is_current

    FROM resolved

)

SELECT * FROM final