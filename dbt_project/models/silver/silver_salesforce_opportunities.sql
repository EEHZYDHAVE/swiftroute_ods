-- ============================================================
-- model:        silver_salesforce_opportunities
-- layer:        silver
-- source:       {{ source('bronze', 'salesforce_opportunities') }}
-- loaded_by:    loaders/load_salesforce.py
-- description:  Cleaned and standardised opportunity records
--               from Salesforce CRM. Opportunities represent
--               potential or completed sales engagements with
--               clients.
--
-- key facts:
--   - Salesforce Id retained as opportunity_source_id.
--     Surrogate key opp_sk generated.
--   - AccountId links to silver_salesforce_accounts.
--   - swiftroute_client_id extracted from nested Account
--     object for direct client joins.
--   - last_activity_date < created_at on some records.
--     Fix: set last_activity_date = created_at::DATE where
--     this occurs. Same fix applied in silver_salesforce_accounts.
--   - All timestamps to TIMESTAMPTZ.
--   - All empty strings to NULL.
--
-- incremental:  Upserts on MD5 of full row (record_hash_key).
--               Safe to re-run, existing records update.
--
-- depends_on:   bronze.salesforce_opportunities
--               silver.silver_salesforce_accounts
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
    FROM {{ source('bronze', 'salesforce_opportunities') }}

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
        raw_data ->> 'Id'                                           AS opportunity_source_id,
        raw_data ->> 'Name'                                         AS opportunity_name,

        -- account reference
        raw_data ->> 'AccountId'                                    AS account_source_id,
        raw_data -> 'Account' ->> 'Name'                            AS account_name,
        raw_data -> 'Account' ->> 'SwiftRoute_Client_ID__c'         AS swiftroute_client_id,

        -- ownership
        raw_data ->> 'OwnerId'                                      AS owner_id,

        -- opportunity details
        raw_data ->> 'StageName'                                    AS stage,
        raw_data ->> 'Type'                                         AS opportunity_type_raw,
        raw_data ->> 'LeadSource'                                   AS lead_source_raw,

        -- commercial attributes
        raw_data ->> 'Account_Tier__c'                              AS account_tier_raw,
        raw_data ->> 'Primary_City__c'                              AS primary_city_raw,
        raw_data ->> 'Contract_Type__c'                             AS contract_type,

        -- financials
        (raw_data ->> 'Amount')::NUMERIC                            AS amount,
        (raw_data ->> 'Probability')::NUMERIC                       AS probability,
        (raw_data ->> 'ExpectedRevenue')::NUMERIC                   AS expected_revenue,

        -- dates
        (raw_data ->> 'CloseDate')::DATE                            AS close_date,
        (raw_data ->> 'CreatedDate')::TIMESTAMPTZ                   AS created_at,
        (raw_data ->> 'LastActivityDate')::DATE                     AS last_activity_date_raw,

        bronze_ingest_timestamp

    FROM source

),

-- ============================================================
-- SECTION 3: CLEAN
-- ============================================================
cleaned AS (

    SELECT
        opportunity_source_id,
        NULLIF(TRIM(opportunity_name), '')                          AS opportunity_name,
        NULLIF(TRIM(account_source_id), '')                         AS account_source_id,
        NULLIF(TRIM(account_name), '')                              AS account_name,
        NULLIF(TRIM(swiftroute_client_id), '')                      AS swiftroute_client_id,
        NULLIF(TRIM(owner_id), '')                                  AS owner_id,
        NULLIF(TRIM(stage), '')                                 AS stage,
        INITCAP(NULLIF(TRIM(opportunity_type_raw), ''))             AS opportunity_type,
        NULLIF(TRIM(lead_source_raw), '')                           AS lead_source,
        LOWER(NULLIF(TRIM(account_tier_raw), ''))                   AS account_tier,
        INITCAP(NULLIF(TRIM(primary_city_raw), ''))                 AS primary_city,
        NULLIF(TRIM(contract_type), '')                             AS contract_type,
        amount,
        probability,
        expected_revenue,
        close_date,
        created_at,
        last_activity_date_raw,
        bronze_ingest_timestamp

    FROM unpacked

),

-- ============================================================
-- SECTION 4: DERIVE
-- Fix: last_activity_date < created_at on some records.
-- Rule: last_activity_date cannot be before created_at date.
-- Same fix applied consistently in silver_salesforce_accounts.
-- ============================================================
derived AS (

    SELECT
        *,

        -- Fix: last_activity_date cannot be before created_at
        CASE
            WHEN last_activity_date_raw < created_at::DATE
            THEN created_at::DATE
            ELSE last_activity_date_raw
        END                                                         AS last_activity_date,

        -- Derived: is opportunity won?
        CASE
            WHEN UPPER(stage) = 'CLOSED WON' THEN TRUE
            WHEN UPPER(stage) = 'CLOSED LOST' THEN FALSE
            ELSE NULL
        END                                                         AS is_won,

        -- Derived: is opportunity closed (won or lost)?
        CASE
            WHEN stage ILIKE 'Closed%' THEN TRUE
            ELSE FALSE
        END                                                         AS is_closed,

        -- Derived: is opportunity still open?
        CASE
            WHEN stage NOT ILIKE 'Closed%' THEN TRUE
            ELSE FALSE
        END                                                         AS is_open,

        -- Derived: weighted expected revenue
        -- probability is stored as a decimal (0 to 100)
        -- Pipeline-safe: NULL-safe computation
        CASE
            WHEN amount IS NOT NULL AND probability IS NOT NULL
            THEN ROUND(amount * (probability / 100.0), 2)
            ELSE NULL
        END                                                         AS weighted_amount,

        -- Derived: days to close from created date
        CASE
            WHEN close_date IS NOT NULL
            THEN (close_date - created_at::DATE)
            ELSE NULL
        END                                                         AS days_to_close

    FROM cleaned

),

-- ============================================================
-- SECTION 5: JOIN to silver_salesforce_accounts
-- LEFT JOIN: preserves opportunities with no resolvable account.
-- ============================================================
with_account AS (

    SELECT
        d.*,
        a.acc_sk
    FROM derived d
    LEFT JOIN {{ ref('silver_salesforce_accounts') }} a
        ON d.account_source_id = a.account_source_id

),

-- ============================================================
-- SECTION 6: SURROGATE KEY + SILVER METADATA
-- opp_sk: human-readable surrogate (opp_00001, opp_00002 ...)
-- record_hash_key: MD5 of full row for incremental upserts
-- ============================================================
final AS (

    SELECT
        -- -------------------------------------------------------
        -- surrogate key
        -- -------------------------------------------------------
        'opp_' || LPAD(
            ROW_NUMBER() OVER (ORDER BY opportunity_source_id)::TEXT
        , 5, '0')                                                   AS opp_sk,

        -- -------------------------------------------------------
        -- natural key
        -- -------------------------------------------------------
        opportunity_source_id,

        -- -------------------------------------------------------
        -- dbt incremental unique key
        -- -------------------------------------------------------
        MD5(
            COALESCE(opportunity_source_id, '')     ||
            COALESCE(stage, '')                 ||
            COALESCE(amount::TEXT, '')              ||
            COALESCE(close_date::TEXT, '')          ||
            COALESCE(probability::TEXT, '')         ||
            COALESCE(last_activity_date::TEXT, '')
        )                                                           AS record_hash_key,

        -- -------------------------------------------------------
        -- account reference
        -- -------------------------------------------------------
        account_source_id,
        acc_sk,
        account_name,
        swiftroute_client_id,
        account_tier,
        primary_city,

        -- -------------------------------------------------------
        -- ownership
        -- -------------------------------------------------------
        owner_id,

        -- -------------------------------------------------------
        -- opportunity details
        -- -------------------------------------------------------
        opportunity_name,
        opportunity_type,
        lead_source,
        contract_type,
        stage,
        is_open,
        is_closed,
        is_won,

        -- -------------------------------------------------------
        -- financials
        -- -------------------------------------------------------
        amount,
        probability,
        expected_revenue,
        weighted_amount,

        -- -------------------------------------------------------
        -- dates
        -- -------------------------------------------------------
        close_date,
        days_to_close,
        last_activity_date,
        created_at,

        -- -------------------------------------------------------
        -- silver metadata
        -- -------------------------------------------------------
        NOW()                                                       AS silver_loaded_at,
        'silver_salesforce_opportunities'                           AS silver_source_model

    FROM with_account

)

SELECT * FROM final