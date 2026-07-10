-- ============================================================
-- model:        silver_salesforce_contract_rates
-- layer:        silver
-- source:       {{ source('bronze', 'salesforce_contract_rates') }}
-- loaded_by:    loaders/load_salesforce.py
-- description:  Cleaned and standardised contract rate records
--               from Salesforce. Each rate record defines the
--               per-delivery price for a specific service type
--               and zone combination under a given contract.
--
-- key facts:
--   - Salesforce Id retained as rate_source_id. Surrogate
--     key rat_sk generated.
--   - Contract__c links to silver_salesforce_contracts via
--     contract_source_id.
--   - Account__c links to silver_salesforce_accounts via
--     account_source_id.
--   - SwiftRoute_Client_ID__c retained as swiftroute_client_id
--     for direct client joins without going through contracts.
--   - net_rate = base_rate * (1 - discount_rate). This is the
--     actual rate charged to the client after discount.
--   - All timestamps to TIMESTAMPTZ.
--   - All empty strings to NULL.
--
-- incremental:  Upserts on MD5 of full row (record_hash_key).
--               Safe to re-run, existing records update.
--
-- depends_on:   bronze.salesforce_contract_rates
--               silver.silver_salesforce_contracts
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
    FROM {{ source('bronze', 'salesforce_contract_rates') }}

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
        raw_data ->> 'Id'                                           AS rate_source_id,

        -- relationships
        raw_data ->> 'Contract__c'                                  AS contract_source_id,
        raw_data ->> 'Account__c'                                   AS account_source_id,
        raw_data ->> 'SwiftRoute_Client_ID__c'                      AS swiftroute_client_id,

        -- service details
        raw_data ->> 'Service_Type__c'                              AS service_type_raw,
        raw_data ->> 'Unit__c'                                      AS unit_raw,

        -- zone
        raw_data ->> 'Zone_ID__c'                                   AS zone_id,
        raw_data ->> 'Zone_Name__c'                                 AS zone_name_raw,

        -- pricing
        (raw_data ->> 'Base_Rate__c')::NUMERIC                      AS base_rate,
        (raw_data ->> 'Net_Rate__c')::NUMERIC                       AS net_rate,
        (raw_data ->> 'Discount_Rate__c')::NUMERIC                  AS discount_rate,

        -- validity
        (raw_data ->> 'Effective_Date__c')::DATE                    AS effective_date,

        -- Salesforce timestamp
        (raw_data ->> 'CreatedDate')::TIMESTAMPTZ                   AS created_at,

        bronze_ingest_timestamp

    FROM source

),

-- ============================================================
-- SECTION 3: CLEAN
-- ============================================================
cleaned AS (

    SELECT
        rate_source_id,
        NULLIF(TRIM(contract_source_id), '')                        AS contract_source_id,
        NULLIF(TRIM(account_source_id), '')                         AS account_source_id,
        NULLIF(TRIM(swiftroute_client_id), '')                      AS swiftroute_client_id,
        LOWER(NULLIF(TRIM(service_type_raw), ''))                   AS service_type,
        LOWER(NULLIF(TRIM(unit_raw), ''))                           AS unit,
        LOWER(NULLIF(TRIM(zone_id), ''))                            AS zone_id,
        INITCAP(NULLIF(TRIM(zone_name_raw), ''))                    AS zone_name,
        base_rate,
        net_rate,
        discount_rate,
        effective_date,
        created_at,
        bronze_ingest_timestamp

    FROM unpacked

),

-- ============================================================
-- SECTION 4: DERIVE
-- ============================================================
derived AS (

    SELECT
        *,

        -- Derived: verify net_rate matches base_rate * (1 - discount)
        -- This is a data quality flag, not a fix. If the source
        -- net_rate differs from the computed value, flag it for
        -- downstream awareness. Pipeline-safe: tolerance of 0.01
        -- accounts for rounding in the source system.
        CASE
            WHEN base_rate IS NOT NULL
            AND discount_rate IS NOT NULL
            AND ABS(
                net_rate - ROUND(base_rate * (1 - discount_rate), 2)
            ) > 0.01
            THEN TRUE
            ELSE FALSE
        END                                                         AS net_rate_discrepancy_flag,

        -- Derived: computed net rate (authoritative calculation)
        CASE
            WHEN base_rate IS NOT NULL AND discount_rate IS NOT NULL
            THEN ROUND(base_rate * (1 - discount_rate), 2)
            ELSE net_rate
        END                                                         AS computed_net_rate,

        -- Derived: service type label
        CASE service_type
            WHEN 'same_day'   THEN 'Same Day'
            WHEN 'next_day'   THEN 'Next Day'
            WHEN 'standard'   THEN 'Standard'
            ELSE INITCAP(COALESCE(service_type, 'Unknown'))
        END                                                         AS service_type_label

    FROM cleaned

),

-- ============================================================
-- SECTION 5: JOIN to contracts and accounts
-- LEFT JOIN on both: rates may exist without a resolvable
-- contract or account in edge cases.
-- ============================================================
with_refs AS (

    SELECT
        d.*,
        c.con_sk,
        c.account_name,
        c.is_active                                                 AS contract_is_active,
        c.start_date                                                AS contract_start_date,
        c.end_date                                                  AS contract_end_date,
        a.acc_sk
    FROM derived d
    LEFT JOIN {{ ref('silver_salesforce_contracts') }} c
        ON d.contract_source_id = c.contract_source_id
    LEFT JOIN {{ ref('silver_salesforce_accounts') }} a
        ON d.account_source_id = a.account_source_id

),

-- ============================================================
-- SECTION 6: SURROGATE KEY + SILVER METADATA
-- rat_sk: human-readable surrogate (rat_00001, rat_00002 ...)
-- record_hash_key: MD5 of full row for incremental upserts
-- ============================================================
final AS (

    SELECT
        -- -------------------------------------------------------
        -- surrogate key
        -- -------------------------------------------------------
        'rat_' || LPAD(
            ROW_NUMBER() OVER (ORDER BY rate_source_id)::TEXT
        , 5, '0')                                                   AS rat_sk,

        -- -------------------------------------------------------
        -- natural key
        -- -------------------------------------------------------
        rate_source_id,

        -- -------------------------------------------------------
        -- dbt incremental unique key
        -- -------------------------------------------------------
        MD5(
            COALESCE(rate_source_id, '')            ||
            COALESCE(contract_source_id, '')        ||
            COALESCE(service_type, '')              ||
            COALESCE(zone_id, '')                   ||
            COALESCE(net_rate::TEXT, '')            ||
            COALESCE(effective_date::TEXT, '')
        )                                                           AS record_hash_key,

        -- -------------------------------------------------------
        -- relationships
        -- -------------------------------------------------------
        contract_source_id,
        con_sk,
        account_source_id,
        acc_sk,
        swiftroute_client_id,
        account_name,
        contract_is_active,
        contract_start_date,
        contract_end_date,

        -- -------------------------------------------------------
        -- service and zone
        -- -------------------------------------------------------
        service_type,
        service_type_label,
        unit,
        zone_id,
        zone_name,

        -- -------------------------------------------------------
        -- pricing
        -- -------------------------------------------------------
        base_rate,
        discount_rate,
        net_rate,
        computed_net_rate,
        net_rate_discrepancy_flag,

        -- -------------------------------------------------------
        -- validity
        -- -------------------------------------------------------
        effective_date,

        -- -------------------------------------------------------
        -- timestamps
        -- -------------------------------------------------------
        created_at,

        -- -------------------------------------------------------
        -- silver metadata
        -- -------------------------------------------------------
        NOW()                                                       AS silver_loaded_at,
        'silver_salesforce_contract_rates'                          AS silver_source_model

    FROM with_refs

)

SELECT * FROM final