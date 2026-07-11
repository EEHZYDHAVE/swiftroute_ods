-- ============================================================
-- model:        dim_vehicle
-- layer:        gold_operations (conformed dimension)
-- description:  Vehicle dimension from Samsara fleet data.
--               Defines the physical assets used to fulfil
--               deliveries across the SwiftRoute network.
--
-- key facts:
--   - vehicle_key: samsara vehicle_id (e.g. "42554227").
--     Used as FK in fact_delivery.
--   - vehicle_sk from silver retained as a reference key.
--   - ownership: derived from vehicle_type and city context.
--     SwiftRoute owns vans and trucks. Motorcycles and cars
--     are typically operated by IC drivers using personal
--     vehicles. This is a business rule approximation since
--     no ownership field exists in the source data.
--   - city and region derived from vehicle tags in silver.
--   - Operational status and is_active reflect current
--     Samsara telemetry state.
--
-- materialized: table (conformed dimension, full rebuild
--               each run reflects current fleet state)
--
-- depends_on:   silver.silver_samsara_vehicles
-- ============================================================

{{
    config(
        materialized='table',
        schema='gold_operations'
    )
}}

-- ============================================================
-- SECTION 1: SOURCE
-- ============================================================
WITH vehicles AS (

    SELECT
        vehicle_id,
        vehicle_sk,
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
        current_odometer_meters,
        current_odometer_km,
        last_latitude,
        last_longitude,
        tags_raw
    FROM {{ ref('silver_samsara_vehicles') }}

),

-- ============================================================
-- SECTION 2: ENRICH
-- Derive ownership and vehicle category from vehicle_type.
-- Business rule: vans and trucks are company-owned assets.
-- Motorcycles and cars are IC driver personal vehicles.
-- Pipeline-safe: ILIKE pattern matching handles variations.
-- ============================================================
enriched AS (

    SELECT
        *,

        -- Derived: ownership classification
        CASE
            WHEN vehicle_type ILIKE '%van%'
            OR vehicle_type ILIKE '%truck%'    THEN 'Company Owned'
            WHEN vehicle_type ILIKE '%motor%'
            OR vehicle_type ILIKE '%car%'      THEN 'Driver Owned'
            ELSE 'Unknown'
        END                                                         AS ownership,

        -- Derived: vehicle category for reporting
        CASE
            WHEN vehicle_type ILIKE '%motor%'  THEN 'Two Wheeler'
            WHEN vehicle_type ILIKE '%car%'    THEN 'Passenger Car'
            WHEN vehicle_type ILIKE '%van%'    THEN 'Van'
            WHEN vehicle_type ILIKE '%truck%'  THEN 'Truck'
            ELSE 'Other'
        END                                                         AS vehicle_category,

        -- Derived: region from city
        CASE
            WHEN city = 'Denver'           THEN 'Colorado'
            WHEN city = 'Albuquerque'      THEN 'New Mexico'
            WHEN city = 'Salt Lake City'   THEN 'Utah'
            ELSE 'Unknown'
        END                                                         AS region

    FROM vehicles

)

-- ============================================================
-- SECTION 3: FINAL SELECT
-- vehicle_key = vehicle_id from Samsara.
-- ============================================================
SELECT
    -- -------------------------------------------------------
    -- primary key
    -- -------------------------------------------------------
    vehicle_id                                                      AS vehicle_key,

    -- -------------------------------------------------------
    -- source reference
    -- -------------------------------------------------------
    vehicle_sk,

    -- -------------------------------------------------------
    -- vehicle identity
    -- -------------------------------------------------------
    vehicle_name,
    make,
    model,
    manufacture_year                                                AS year,
    vin,
    license_plate,

    -- -------------------------------------------------------
    -- classification
    -- -------------------------------------------------------
    vehicle_type,
    vehicle_category,
    fuel_type,
    ownership,

    -- -------------------------------------------------------
    -- location
    -- -------------------------------------------------------
    city,
    region,

    -- -------------------------------------------------------
    -- status
    -- -------------------------------------------------------
    operational_status,
    is_active,

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
    tags_raw

FROM enriched

ORDER BY vehicle_id