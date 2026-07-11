-- ============================================================
-- model:        dim_client
-- layer:        gold_operations (conformed dimension)
-- description:  Client dimension combining account attributes
--               from Salesforce accounts and commercial terms
--               from Salesforce contracts. This is the
--               AUTHORITATIVE client reference used across
--               all three fact tables.
--
-- key facts:
--   - client_key: swiftroute_client_id (e.g. client_001).
--     This is the cross-system client identifier present in
--     Onfleet metadata, Linnworks, and QuickBooks. Used as
--     FK in all fact tables.
--   - contract_id: the active contract for this client.
--     Where a client has multiple contracts, the most
--     recently activated contract is used.
--   - fulfillment_flag: TRUE for clients whose orders are
--     fulfilled via Linnworks warehouse operations.
--   - payment_terms: net payment days from the contract.
--   - All attributes sourced from silver, no hardcoding.
--
-- materialized: table (conformed dimension, full rebuild
--               each run ensures current contract terms
--               are always reflected)
--
-- depends_on:   silver.silver_salesforce_accounts
--               silver.silver_salesforce_contracts
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
WITH accounts AS (

    SELECT
        swiftroute_client_id,
        account_source_id,
        acc_sk,
        account_name,
        industry,
        account_tier,
        primary_city,
        discount_rate,
        net_payment_terms_days,
        is_fulfillment_client,
        contracted_monthly_volume,
        annual_revenue,
        number_of_employees,
        is_active
    FROM {{ ref('silver_salesforce_accounts') }}
    WHERE swiftroute_client_id IS NOT NULL

),

-- ============================================================
-- SECTION 2: RESOLVE ACTIVE CONTRACT
-- Where a client has multiple contracts, select the most
-- recently activated one. Pipeline-safe: ROW_NUMBER ensures
-- one row per client regardless of contract count.
-- ============================================================
contracts_ranked AS (

    SELECT
        swiftroute_client_id,
        con_sk,
        contract_source_id,
        contract_type,
        net_payment_terms_days                                      AS contract_payment_terms,
        discount_rate                                               AS contract_discount_rate,
        committed_monthly_volume,
        start_date                                                  AS contract_start_date,
        end_date                                                    AS contract_end_date,
        is_active                                                   AS contract_is_active,
        ROW_NUMBER() OVER (
            PARTITION BY swiftroute_client_id
            ORDER BY
                is_active DESC,
                start_date DESC
        )                                                           AS contract_rank
    FROM {{ ref('silver_salesforce_contracts') }}
    WHERE swiftroute_client_id IS NOT NULL

),

active_contract AS (

    SELECT *
    FROM contracts_ranked
    WHERE contract_rank = 1

),

-- ============================================================
-- SECTION 3: JOIN ACCOUNTS TO CONTRACTS
-- LEFT JOIN: clients without a contract are preserved.
-- Account-level terms used as fallback where contract
-- terms are not available.
-- ============================================================
joined AS (

    SELECT
        a.swiftroute_client_id,
        a.account_source_id,
        a.acc_sk,
        a.account_name,
        a.industry,
        a.account_tier,
        a.primary_city,
        a.is_fulfillment_client,
        a.contracted_monthly_volume,
        a.annual_revenue,
        a.number_of_employees,
        a.is_active                                                 AS account_is_active,

        -- contract terms (fall back to account-level if no contract)
        c.con_sk,
        c.contract_source_id,
        c.contract_type,
        c.contract_start_date,
        c.contract_end_date,
        c.contract_is_active,
        COALESCE(
            c.contract_payment_terms,
            a.net_payment_terms_days
        )                                                           AS payment_terms,
        COALESCE(
            c.contract_discount_rate,
            a.discount_rate
        )                                                           AS discount_rate

    FROM accounts a
    LEFT JOIN active_contract c
        ON a.swiftroute_client_id = c.swiftroute_client_id

)

-- ============================================================
-- SECTION 4: FINAL SELECT
-- client_key = swiftroute_client_id, the cross-system
-- identifier used in all fact tables.
-- ============================================================
SELECT
    -- -------------------------------------------------------
    -- primary key
    -- -------------------------------------------------------
    swiftroute_client_id                                            AS client_key,

    -- -------------------------------------------------------
    -- source references
    -- -------------------------------------------------------
    account_source_id,
    acc_sk,
    con_sk,
    contract_source_id,

    -- -------------------------------------------------------
    -- client identity
    -- -------------------------------------------------------
    account_name                                                    AS client_name,
    industry,
    account_tier,
    primary_city                                                    AS city,

    -- -------------------------------------------------------
    -- commercial terms
    -- -------------------------------------------------------
    contract_type,
    discount_rate,
    payment_terms,
    is_fulfillment_client                                           AS fulfillment_flag,
    contracted_monthly_volume,

    -- -------------------------------------------------------
    -- contract dates
    -- -------------------------------------------------------
    contract_start_date,
    contract_end_date,
    contract_is_active,

    -- -------------------------------------------------------
    -- company profile
    -- -------------------------------------------------------
    annual_revenue,
    number_of_employees,
    account_is_active

FROM joined

ORDER BY swiftroute_client_id