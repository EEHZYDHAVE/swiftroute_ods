-- ============================================================
-- model:        dim_service_type
-- layer:        gold_operations (conformed dimension)
-- description:  Service type dimension derived from distinct
--               service_type values in Onfleet delivery
--               metadata and Salesforce contract rates.
--               Defines the delivery service tiers offered
--               by SwiftRoute.
--
-- key facts:
--   - service_type_key: raw service_type value from source
--     (e.g. same_day, next_day, standard). Used as FK in
--     fact_delivery and dim_contract_rate.
--   - sla_hours: the SLA commitment for each service type.
--     Derived from known business rules, not a source column.
--   - vehicle_required: minimum vehicle type required to
--     fulfil each service tier.
--   - pricing_tier: relative pricing band for reporting.
--   - UNION of service types from both delivery and contract
--     rate tables ensures completeness. Pipeline-safe: new
--     service types in future data runs are included
--     automatically with conservative default values.
--
-- materialized: table (very small, full rebuild each run)
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
-- SECTION 1: COLLECT ALL DISTINCT SERVICE TYPES
-- Union from all silver sources that carry service_type.
-- ============================================================
WITH service_types_from_deliveries AS (

    SELECT DISTINCT
        service_type                                                AS service_type_key
    FROM {{ ref('silver_onfleet_deliveries') }}
    WHERE service_type IS NOT NULL

),

service_types_from_contract_rates AS (

    SELECT DISTINCT
        service_type                                                AS service_type_key
    FROM {{ ref('silver_salesforce_contract_rates') }}
    WHERE service_type IS NOT NULL

),

all_service_types AS (

    SELECT service_type_key FROM service_types_from_deliveries
    UNION
    SELECT service_type_key FROM service_types_from_contract_rates

),

-- ============================================================
-- SECTION 2: ENRICH
-- Derive SLA hours, vehicle requirement, pricing tier, and
-- human-readable label from service_type_key.
-- Business rules encoded here are stable SwiftRoute
-- operational definitions. Pipeline-safe: new service types
-- fall through to conservative defaults rather than failing.
-- ============================================================
enriched AS (

    SELECT
        service_type_key,

        -- Derived: human-readable service type name
        CASE service_type_key
            WHEN 'same_day'  THEN 'Same Day Delivery'
            WHEN 'next_day'  THEN 'Next Day Delivery'
            WHEN 'standard'  THEN 'Standard Delivery'
            ELSE INITCAP(REPLACE(service_type_key, '_', ' '))
        END                                                         AS service_type_name,

        -- Derived: SLA commitment in hours
        -- Business rule: same_day = 8hrs, next_day = 24hrs,
        -- standard = 72hrs. Default 48hrs for unknown types.
        CASE service_type_key
            WHEN 'same_day'  THEN 8
            WHEN 'next_day'  THEN 24
            WHEN 'standard'  THEN 72
            ELSE 48
        END                                                         AS sla_hours,

        -- Derived: minimum vehicle type required
        CASE service_type_key
            WHEN 'same_day'  THEN 'Motorcycle or Car'
            WHEN 'next_day'  THEN 'Car or Van'
            WHEN 'standard'  THEN 'Any'
            ELSE 'Any'
        END                                                         AS vehicle_required,

        -- Derived: pricing tier for reporting
        CASE service_type_key
            WHEN 'same_day'  THEN 'Premium'
            WHEN 'next_day'  THEN 'Standard'
            WHEN 'standard'  THEN 'Economy'
            ELSE 'Standard'
        END                                                         AS pricing_tier,

        -- Derived: sort order for reporting
        CASE service_type_key
            WHEN 'same_day'  THEN 1
            WHEN 'next_day'  THEN 2
            WHEN 'standard'  THEN 3
            ELSE 99
        END                                                         AS sort_order

    FROM all_service_types

)

-- ============================================================
-- SECTION 3: FINAL SELECT
-- ============================================================
SELECT
    service_type_key,
    service_type_name,
    sla_hours,
    vehicle_required,
    pricing_tier,
    sort_order

FROM enriched

ORDER BY sort_order