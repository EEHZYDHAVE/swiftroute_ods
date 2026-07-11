-- ============================================================
-- model:        dim_driver
-- layer:        gold_operations (conformed dimension)
-- description:  Driver dimension combining identity and
--               attributes from Onfleet, Gusto, and Samsara.
--               Uses driver_id_map as the cross-system bridge
--               to resolve one canonical record per driver.
--
-- key facts:
--   - driver_key: canonical_driver_key from driver_id_map
--     (= onfleet_worker_id, e.g. drv_fte_001). This is the
--     FK used in fact_delivery.
--   - driver_type: FTE (Full-Time Employee) or IC
--     (Independent Contractor). Sourced from Onfleet workers.
--   - gusto_uuid: links to payroll data for labour cost
--     calculations in fact_delivery.
--   - samsara_driver_id: links to telematics for safety
--     scoring.
--   - safety_score: lifetime safety score from Samsara
--     driver summary.
--   - is_active: FALSE for the one terminated driver.
--     Canonical across all source systems.
--
-- materialized: table (conformed dimension, full rebuild
--               each run reflects current driver roster)
--
-- depends_on:   driver_id_map
--               silver.silver_gusto_employees
--               silver.silver_samsara_driver_summary
--               silver.silver_onfleet_workers
-- ============================================================

{{
    config(
        materialized='table',
        schema='gold_operations'
    )
}}

-- ============================================================
-- SECTION 1: SOURCE FROM driver_id_map
-- Start from the authoritative cross-system identity map.
-- ============================================================
WITH id_map AS (

    SELECT
        canonical_driver_key,
        onfleet_worker_id,
        gusto_uuid,
        samsara_driver_id,
        driver_name,
        employment_type,
        is_active
    FROM {{ ref('driver_id_map') }}

),

-- ============================================================
-- SECTION 2: ENRICH FROM GUSTO
-- Pull employment and compensation attributes for FTE drivers.
-- ============================================================
gusto AS (

    SELECT
        employee_source_id                                          AS gusto_uuid,
        department,
        job_title,
        hire_date,
        termination_date,
        annual_salary,
        bi_weekly_gross,
        years_of_service
    FROM {{ ref('silver_gusto_employees') }}
    WHERE is_driver = TRUE

),

-- ============================================================
-- SECTION 3: ENRICH FROM SAMSARA
-- Pull safety metrics from driver summary.
-- ============================================================
samsara AS (

    SELECT
        driver_source_id                                            AS samsara_driver_id,
        safety_score,
        safety_score_band,
        total_trips,
        total_distance_km,
        total_safety_incidents,
        city                                                        AS samsara_city
    FROM {{ ref('silver_samsara_driver_summary') }}

),

-- ============================================================
-- SECTION 4: ENRICH FROM ONFLEET WORKERS
-- Pull vehicle and team attributes.
-- ============================================================
onfleet AS (

    SELECT
        worker_id                                                   AS onfleet_worker_id,
        city                                                        AS onfleet_city,
        vehicle_type                                                AS onfleet_vehicle_type,
        vehicle_description,
        vehicle_license_plate,
        primary_team
    FROM {{ ref('silver_onfleet_workers') }}

),

-- ============================================================
-- SECTION 5: JOIN ALL SOURCES
-- Left join from id_map so all drivers are preserved even
-- if they do not appear in Gusto or Samsara.
-- ============================================================
joined AS (

    SELECT
        m.canonical_driver_key,
        m.onfleet_worker_id,
        m.gusto_uuid,
        m.samsara_driver_id,
        m.driver_name,
        m.employment_type,
        m.is_active,

        -- from Gusto
        g.department,
        g.job_title,
        g.hire_date,
        g.termination_date,
        g.annual_salary,
        g.bi_weekly_gross,
        g.years_of_service,

        -- from Samsara
        s.safety_score,
        s.safety_score_band,
        s.total_trips,
        s.total_distance_km,
        s.total_safety_incidents,

        -- from Onfleet
        o.onfleet_city                                              AS city,
        o.onfleet_vehicle_type                                      AS preferred_vehicle_type,
        o.vehicle_description,
        o.vehicle_license_plate,
        o.primary_team

    FROM id_map m
    LEFT JOIN gusto g
        ON m.gusto_uuid = g.gusto_uuid
    LEFT JOIN samsara s
        ON m.samsara_driver_id = s.samsara_driver_id
    LEFT JOIN onfleet o
        ON m.onfleet_worker_id = o.onfleet_worker_id

)

-- ============================================================
-- SECTION 6: FINAL SELECT
-- driver_key = canonical_driver_key from driver_id_map.
-- ============================================================
SELECT
    -- -------------------------------------------------------
    -- primary key
    -- -------------------------------------------------------
    canonical_driver_key                                            AS driver_key,

    -- -------------------------------------------------------
    -- source system IDs (kept for traceability)
    -- -------------------------------------------------------
    onfleet_worker_id,
    gusto_uuid,
    samsara_driver_id,

    -- -------------------------------------------------------
    -- driver identity
    -- -------------------------------------------------------
    driver_name,
    employment_type                                                 AS driver_type,
    city,
    primary_team,
    department,
    job_title,

    -- -------------------------------------------------------
    -- employment
    -- -------------------------------------------------------
    hire_date,
    termination_date,
    is_active,
    years_of_service,

    -- -------------------------------------------------------
    -- compensation
    -- -------------------------------------------------------
    annual_salary,
    bi_weekly_gross,

    -- -------------------------------------------------------
    -- vehicle preference
    -- -------------------------------------------------------
    preferred_vehicle_type,
    vehicle_description,
    vehicle_license_plate,

    -- -------------------------------------------------------
    -- safety metrics
    -- -------------------------------------------------------
    safety_score,
    safety_score_band,
    total_trips,
    total_distance_km,
    total_safety_incidents

FROM joined

ORDER BY canonical_driver_key