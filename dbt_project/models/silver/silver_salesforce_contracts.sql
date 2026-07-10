-- ============================================================
-- model:        silver_salesforce_contracts
-- layer:        silver
-- source:       {{ source('bronze', 'salesforce_contracts') }}
-- loaded_by:    loaders/load_salesforce.py
-- description:  Cleaned and standardised contract records from
--               Salesforce CRM. Contracts define the commercial
--               terms between SwiftRoute and each client.
--
-- key facts:
--   - Salesforce Id retained as contract_source_id. Surrogate
--     key con_sk generated.
--   - AccountId is NULL on some contracts (known simulation
--     quirk, not a data quality error). These contracts are
--     kept as-is. NULL AccountId means the contract cannot
--     be joined to silver_salesforce_accounts for those rows.
--   - contract_source_id is the join key to
--     silver_salesforce_contract_rates.
--   - All timestamps to TIMESTAMPTZ.
--   - All empty strings to NULL.
--
-- incremental:  Upserts on MD5 of full row (record_hash_key).
--               Safe to re-run, existing records update.
--
-- depends_on:   bronze.salesforce_contracts
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
    FROM {{ source('bronze', 'salesforce_contracts') }}

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
        raw_data ->> 'Id'                                           AS contract_source_id,

        -- account reference (may be NULL, known quirk)
        raw_data ->> 'AccountId'                                    AS account_source_id,

        -- ownership
        raw_data ->> 'OwnerId'                                      AS owner_id,

        -- contract dates
        (raw_data ->> 'StartDate')::DATE                            AS start_date,
        (raw_data ->> 'EndDate')::DATE                              AS end_date,
        (raw_data ->> 'SignedDate__c')::DATE                        AS signed_date,

        -- lifecycle
        raw_data ->> 'Status'                                       AS status_raw,
        raw_data ->> 'Contract_Type__c'                             AS contract_type,
        (raw_data ->> 'Auto_Renewal__c')::BOOLEAN                   AS auto_renewal,

        -- commercial terms
        (raw_data ->> 'ContractTerm')::INT                          AS contract_term_months,
        (raw_data ->> 'Discount_Rate__c')::NUMERIC                  AS discount_rate,
        (raw_data ->> 'Net_Payment_Terms__c')::INT                  AS net_payment_terms_days,
        (raw_data ->> 'Termination_Notice_Days__c')::INT            AS termination_notice_days,
        (raw_data ->> 'Committed_Monthly_Volume__c')::INT           AS committed_monthly_volume,

        -- customer attributes
        raw_data ->> 'Account_Tier__c'                              AS account_tier_raw,
        raw_data ->> 'Primary_City__c'                              AS primary_city_raw,

        -- Salesforce timestamps
        (raw_data ->> 'CreatedDate')::TIMESTAMPTZ                   AS created_at,
        (raw_data ->> 'LastModifiedDate')::TIMESTAMPTZ              AS last_modified_at,

        bronze_ingest_timestamp

    FROM source

),

-- ============================================================
-- SECTION 3: CLEAN
-- ============================================================
cleaned AS (

    SELECT
        contract_source_id,
        NULLIF(TRIM(account_source_id), '')                         AS account_source_id,
        NULLIF(TRIM(owner_id), '')                                  AS owner_id,
        start_date,
        end_date,
        signed_date,
        INITCAP(NULLIF(TRIM(status_raw), ''))                       AS status,
        NULLIF(TRIM(contract_type), '')                             AS contract_type,
        auto_renewal,
        contract_term_months,
        discount_rate,
        net_payment_terms_days,
        termination_notice_days,
        committed_monthly_volume,
        LOWER(NULLIF(TRIM(account_tier_raw), ''))                   AS account_tier,
        INITCAP(NULLIF(TRIM(primary_city_raw), ''))                 AS primary_city,
        created_at,
        last_modified_at,
        bronze_ingest_timestamp

    FROM unpacked

),

-- ============================================================
-- SECTION 4: DERIVE
-- ============================================================
derived AS (

    SELECT
        *,

        -- Derived: is contract currently active?
        -- Active means status = Activated AND end_date >= today.
        -- Pipeline-safe: uses CURRENT_DATE, not a hardcoded date.
        CASE
            WHEN UPPER(status) = 'ACTIVATED'
            AND end_date >= CURRENT_DATE
            THEN TRUE
            ELSE FALSE
        END                                                         AS is_active,

        -- Derived: days remaining on contract
        -- NULL if contract already expired or not yet active.
        CASE
            WHEN end_date >= CURRENT_DATE
            THEN (end_date - CURRENT_DATE)
            ELSE NULL
        END                                                         AS days_remaining,

        -- Derived: contract duration in months (actual vs term)
        CASE
            WHEN start_date IS NOT NULL AND end_date IS NOT NULL
            THEN ROUND(
                (end_date - start_date) / 30.44
            , 1)
            ELSE NULL
        END                                                         AS actual_duration_months

    FROM cleaned

),

-- ============================================================
-- SECTION 5: JOIN to silver_salesforce_accounts
-- LEFT JOIN: preserves contracts with NULL AccountId.
-- Resolves acc_sk and swiftroute_client_id for contracts
-- where AccountId is present.
-- ============================================================
with_account AS (

    SELECT
        d.*,
        a.acc_sk,
        a.swiftroute_client_id,
        a.account_name
    FROM derived d
    LEFT JOIN {{ ref('silver_salesforce_accounts') }} a
        ON d.account_source_id = a.account_source_id

),

-- ============================================================
-- SECTION 6: SURROGATE KEY + SILVER METADATA
-- con_sk: human-readable surrogate (con_00001, con_00002 ...)
-- record_hash_key: MD5 of full row for incremental upserts
-- ============================================================
final AS (

    SELECT
        -- -------------------------------------------------------
        -- surrogate key
        -- -------------------------------------------------------
        'con_' || LPAD(
            ROW_NUMBER() OVER (ORDER BY contract_source_id)::TEXT
        , 5, '0')                                                   AS con_sk,

        -- -------------------------------------------------------
        -- natural key
        -- -------------------------------------------------------
        contract_source_id,

        -- -------------------------------------------------------
        -- dbt incremental unique key
        -- -------------------------------------------------------
        MD5(
            COALESCE(contract_source_id, '')            ||
            COALESCE(account_source_id, '')             ||
            COALESCE(status, '')                        ||
            COALESCE(discount_rate::TEXT, '')           ||
            COALESCE(end_date::TEXT, '')                ||
            COALESCE(last_modified_at::TEXT, '')
        )                                                           AS record_hash_key,

        -- -------------------------------------------------------
        -- account reference
        -- -------------------------------------------------------
        account_source_id,
        acc_sk,
        swiftroute_client_id,
        account_name,
        account_tier,
        primary_city,

        -- -------------------------------------------------------
        -- ownership
        -- -------------------------------------------------------
        owner_id,

        -- -------------------------------------------------------
        -- contract lifecycle
        -- -------------------------------------------------------
        status,
        contract_type,
        auto_renewal,
        is_active,

        -- -------------------------------------------------------
        -- dates
        -- -------------------------------------------------------
        signed_date,
        start_date,
        end_date,
        days_remaining,

        -- -------------------------------------------------------
        -- commercial terms
        -- -------------------------------------------------------
        contract_term_months,
        actual_duration_months,
        discount_rate,
        net_payment_terms_days,
        termination_notice_days,
        committed_monthly_volume,

        -- -------------------------------------------------------
        -- timestamps
        -- -------------------------------------------------------
        created_at,
        last_modified_at,

        -- -------------------------------------------------------
        -- silver metadata
        -- -------------------------------------------------------
        NOW()                                                       AS silver_loaded_at,
        'silver_salesforce_contracts'                               AS silver_source_model

    FROM with_account

)

SELECT * FROM final