-- ============================================================
-- model:        dim_contract_rate
-- layer:        gold_operations (conformed dimension)
-- description:  Contract rate dimension from Salesforce.
--               Defines the per-delivery pricing for each
--               client, service type, and zone combination.
--               Used in fact_delivery and fact_invoice to
--               apply the correct contracted rate to each
--               transaction.
--
-- key facts:
--   - contract_rate_key: rat_sk from silver (e.g. rat_00001).
--     Used as FK in fact_delivery and fact_invoice.
--   - client_key: swiftroute_client_id for joining to
--     dim_client.
--   - net_rate: the actual rate charged after discount.
--     computed_net_rate from silver is used where a
--     discrepancy exists between source net_rate and the
--     mathematically correct value.
--   - effective_date: when this rate became active. Used to
--     resolve the correct rate for a delivery on a given date.
--   - expiry_date: not present in source data, set to NULL.
--     Can be populated via SCD2 in future runs.
--   - contract_is_active: reflects whether the parent
--     contract is currently active.
--
-- materialized: table (conformed dimension, full rebuild
--               each run reflects current rate cards)
--
-- depends_on:   silver.silver_salesforce_contract_rates
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
WITH contract_rates AS (

    SELECT
        rat_sk,
        rate_source_id,
        contract_source_id,
        con_sk,
        account_source_id,
        acc_sk,
        swiftroute_client_id,
        account_name,
        service_type,
        service_type_label,
        unit,
        zone_id,
        zone_name,
        base_rate,
        discount_rate,
        net_rate,
        computed_net_rate,
        net_rate_discrepancy_flag,
        effective_date,
        contract_is_active,
        contract_start_date,
        contract_end_date
    FROM {{ ref('silver_salesforce_contract_rates') }}

)

-- ============================================================
-- SECTION 2: FINAL SELECT
-- contract_rate_key = rat_sk from silver.
-- net_rate resolved: use computed_net_rate where source
-- net_rate has a discrepancy, else use source net_rate.
-- expiry_date set to contract_end_date as best available
-- approximation since no explicit expiry exists in source.
-- ============================================================
SELECT
    -- -------------------------------------------------------
    -- primary key
    -- -------------------------------------------------------
    rat_sk                                                          AS contract_rate_key,

    -- -------------------------------------------------------
    -- source references
    -- -------------------------------------------------------
    rate_source_id,
    contract_source_id,
    con_sk,
    account_source_id,
    acc_sk,

    -- -------------------------------------------------------
    -- client reference
    -- -------------------------------------------------------
    swiftroute_client_id                                            AS client_key,
    account_name                                                    AS client_name,

    -- -------------------------------------------------------
    -- service and zone
    -- -------------------------------------------------------
    service_type,
    service_type_label,
    unit,
    zone_id,
    zone_name,

    -- -------------------------------------------------------
    -- pricing (use computed rate where discrepancy exists)
    -- -------------------------------------------------------
    base_rate,
    discount_rate,
    CASE
        WHEN net_rate_discrepancy_flag = TRUE
        THEN computed_net_rate
        ELSE net_rate
    END                                                             AS net_rate,
    net_rate_discrepancy_flag,

    -- -------------------------------------------------------
    -- validity dates
    -- -------------------------------------------------------
    effective_date,
    contract_end_date                                               AS expiry_date,
    contract_is_active,
    contract_start_date

FROM contract_rates

ORDER BY swiftroute_client_id, service_type, zone_id