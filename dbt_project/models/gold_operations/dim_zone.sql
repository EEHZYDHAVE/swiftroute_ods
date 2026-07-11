-- ============================================================
-- model:        dim_zone
-- layer:        gold_operations (conformed dimension)
-- description:  Delivery zone dimension derived from zone_id
--               values present in Onfleet delivery metadata
--               and Salesforce contract rates. Zones represent
--               geographic delivery areas within each city.
--
-- key facts:
--   - zone_key: the raw zone_id from source systems
--     (e.g. zone_den_1, zone_abq_4, zone_slc_2).
--     Used as FK in all fact tables.
--   - zone_name: human-readable label derived from zone_key.
--   - city and region derived from zone_key prefix pattern.
--     Pattern: zone_{city_code}_{number}
--     den = Denver, abq = Albuquerque, slc = Salt Lake City.
--   - capacity removed from design (no source data available).
--   - UNION of zone_ids from both source systems ensures all
--     zones referenced in any fact table exist in this
--     dimension. Pipeline-safe: new zones in future data
--     runs are automatically included.
--
-- materialized: table (small reference table, full rebuild
--               each run is cheap and always current)
--
-- depends_on:   silver.silver_onfleet_deliveries
--               silver.silver_salesforce_contract_rates
-- ============================================================

{{
    config(
        materialized='table',
        schema='gold_operations'
    )
}}

-- ============================================================
-- SECTION 1: COLLECT ALL DISTINCT ZONE IDs
-- Union zone_ids from all silver sources that carry zone data.
-- This guarantees every zone referenced in fact tables has
-- a matching row in dim_zone.
-- ============================================================
WITH zones_from_deliveries AS (

    SELECT DISTINCT
        zone_id                                                     AS zone_key
    FROM {{ ref('silver_onfleet_deliveries') }}
    WHERE zone_id IS NOT NULL

),

zones_from_contract_rates AS (

    SELECT DISTINCT
        zone_id                                                     AS zone_key
    FROM {{ ref('silver_salesforce_contract_rates') }}
    WHERE zone_id IS NOT NULL

),

all_zones AS (

    SELECT zone_key FROM zones_from_deliveries
    UNION
    SELECT zone_key FROM zones_from_contract_rates

),

-- ============================================================
-- SECTION 2: ENRICH
-- Derive city, region, and human-readable zone name from
-- zone_key using pattern matching. Pattern: zone_{city}_{n}
-- Pipeline-safe: ILIKE matching handles minor variations.
-- ============================================================
enriched AS (

    SELECT
        zone_key,

        -- Derived: city from zone_key prefix
        CASE
            WHEN zone_key ILIKE '%den%' THEN 'Denver'
            WHEN zone_key ILIKE '%abq%' THEN 'Albuquerque'
            WHEN zone_key ILIKE '%slc%' THEN 'Salt Lake City'
            ELSE 'Unknown'
        END                                                         AS city,

        -- Derived: region (state) from city
        CASE
            WHEN zone_key ILIKE '%den%' THEN 'Colorado'
            WHEN zone_key ILIKE '%abq%' THEN 'New Mexico'
            WHEN zone_key ILIKE '%slc%' THEN 'Utah'
            ELSE 'Unknown'
        END                                                         AS region,

        -- Derived: zone number extracted from zone_key
        -- Pattern: zone_den_1 -> 1
        -- Pipeline-safe: SPLIT_PART handles the suffix cleanly
        SPLIT_PART(zone_key, '_', 3)                                AS zone_number,

        -- Derived: human-readable zone name
        CASE
            WHEN zone_key ILIKE '%den%'
            THEN 'Denver Zone ' || SPLIT_PART(zone_key, '_', 3)
            WHEN zone_key ILIKE '%abq%'
            THEN 'Albuquerque Zone ' || SPLIT_PART(zone_key, '_', 3)
            WHEN zone_key ILIKE '%slc%'
            THEN 'Salt Lake City Zone ' || SPLIT_PART(zone_key, '_', 3)
            ELSE zone_key
        END                                                         AS zone_name

    FROM all_zones

)

-- ============================================================
-- SECTION 3: FINAL SELECT
-- zone_key is the PK and FK used in all fact tables.
-- ============================================================
SELECT
    zone_key,
    zone_name,
    zone_number,
    city,
    region

FROM enriched

ORDER BY city, zone_number