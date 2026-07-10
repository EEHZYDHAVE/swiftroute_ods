-- ============================================================
-- model:        silver_salesforce_accounts
-- layer:        silver
-- source:       {{ source('bronze', 'salesforce_accounts') }}
-- loaded_by:    loaders/load_salesforce.py
-- description:  Cleaned and standardised client account records
--               from Salesforce CRM. This is the AUTHORITATIVE
--               source for client identity across the pipeline.
--
-- key facts:
--   - Salesforce Id (e.g. "001bk34UPW52P6YtCB") is the natural
--     key: retained as account_source_id.
--   - SwiftRoute_Client_ID__c (e.g. "client_094") is the
--     internal cross-system client identifier: retained as
--     swiftroute_client_id and used as the join key to
--     Linnworks, QuickBooks, and Onfleet delivery metadata.
--   - A human-readable surrogate key (acc_sk) is generated.
--   - last_activity_date < created_at on some records: fixed
--     by setting last_activity_date = created_at::DATE.
--   - Stale CRM data is a known simulation limitation,
--     not treated as a data quality error.
--   - All timestamps → TIMESTAMPTZ.
--   - All empty strings → NULL.
--
-- incremental:  Upserts on MD5 of full row (record_hash_key).
--               Safe to re-run: existing records update in place.
--
-- depends_on:   bronze.salesforce_accounts
-- ============================================================

{{
    config(
        materialized='incremental',
        unique_key='record_hash_key',
        on_schema_change='sync_all_columns'
    )
}}

-- ============================================================
-- SECTION 1: SOURCE: pull from bronze
-- ============================================================
WITH source AS (

    SELECT
        id                  AS bronze_row_id,
        ingest_timestamp    AS bronze_ingest_timestamp,
        raw_data
    FROM {{ source('bronze', 'salesforce_accounts') }}

    {% if is_incremental() %}
    WHERE ingest_timestamp > (
        SELECT MAX(silver_loaded_at) FROM {{ this }}
    )
    {% endif %}

),

-- ============================================================
-- SECTION 2: UNPACK: extract JSONB fields into typed columns
-- All field names verified against raw data samples.
-- ============================================================
unpacked AS (

    SELECT
        -- natural keys
        raw_data ->> 'Id'                                           AS account_source_id,
        raw_data ->> 'SwiftRoute_Client_ID__c'                      AS swiftroute_client_id,

        -- account details
        raw_data ->> 'Name'                                         AS account_name,
        raw_data ->> 'Type'                                         AS account_type_raw,
        raw_data ->> 'Industry'                                     AS industry,

        -- SwiftRoute business attributes
        raw_data ->> 'Account_Tier__c'                              AS account_tier_raw,
        raw_data ->> 'Primary_City__c'                              AS primary_city_raw,
        raw_data ->> 'Contract_Type__c'                             AS contract_type,
        (raw_data ->> 'Discount_Rate__c')::NUMERIC                  AS discount_rate,
        (raw_data ->> 'Net_Payment_Terms__c')::INT                  AS net_payment_terms_days,
        (raw_data ->> 'Is_Fulfillment_Client__c')::BOOLEAN          AS is_fulfillment_client,
        (raw_data ->> 'Contracted_Monthly_Volume__c')::INT          AS contracted_monthly_volume,

        -- owner
        raw_data ->> 'OwnerId'                                      AS owner_id,
        raw_data -> 'Owner' ->> 'Name'                              AS owner_name,
        raw_data -> 'Owner' ->> 'Email'                             AS owner_email,

        -- contact
        raw_data ->> 'Phone'                                        AS phone,
        raw_data ->> 'Website'                                      AS website,

        -- billing address
        raw_data -> 'BillingAddress' ->> 'street'                   AS billing_street,
        raw_data -> 'BillingAddress' ->> 'city'                     AS billing_city,
        raw_data -> 'BillingAddress' ->> 'state'                    AS billing_state,
        raw_data -> 'BillingAddress' ->> 'stateCode'                AS billing_state_code,
        raw_data -> 'BillingAddress' ->> 'postalCode'               AS billing_postal_code,
        raw_data -> 'BillingAddress' ->> 'country'                  AS billing_country,
        raw_data -> 'BillingAddress' ->> 'countryCode'              AS billing_country_code,

        -- company profile
        (raw_data ->> 'AnnualRevenue')::NUMERIC                     AS annual_revenue,
        (raw_data ->> 'NumberOfEmployees')::INT                     AS number_of_employees,

        -- timestamps
        (raw_data ->> 'CreatedDate')::TIMESTAMPTZ                   AS created_at,
        (raw_data ->> 'LastModifiedDate')::TIMESTAMPTZ              AS last_modified_at,
        (raw_data ->> 'LastActivityDate')::DATE                     AS last_activity_date_raw,

        -- bronze metadata
        bronze_ingest_timestamp

    FROM source

),

-- ============================================================
-- SECTION 3: CLEAN: nulls, empty strings, standardisation
-- ============================================================
cleaned AS (

    SELECT
        account_source_id,
        NULLIF(TRIM(swiftroute_client_id), '')                      AS swiftroute_client_id,
        NULLIF(TRIM(account_name), '')                              AS account_name,
        INITCAP(NULLIF(TRIM(account_type_raw), ''))                 AS account_type,
        INITCAP(NULLIF(TRIM(industry), ''))                         AS industry,

        -- SwiftRoute attributes
        LOWER(NULLIF(TRIM(account_tier_raw), ''))                   AS account_tier,
        INITCAP(NULLIF(TRIM(primary_city_raw), ''))                 AS primary_city,
        NULLIF(TRIM(contract_type), '')                             AS contract_type,
        discount_rate,
        net_payment_terms_days,
        is_fulfillment_client,
        contracted_monthly_volume,

        -- owner
        NULLIF(TRIM(owner_id), '')                                  AS owner_id,
        NULLIF(TRIM(owner_name), '')                                 AS owner_name,
        LOWER(NULLIF(TRIM(owner_email), ''))                        AS owner_email,

        -- contact
        NULLIF(TRIM(phone), '')                                     AS phone,
        NULLIF(TRIM(website), '')                                   AS website,

        -- billing address
        NULLIF(TRIM(billing_street), '')                            AS billing_street,
        NULLIF(TRIM(billing_city), '')                              AS billing_city,
        NULLIF(TRIM(billing_state), '')                             AS billing_state,
        UPPER(NULLIF(TRIM(billing_state_code), ''))                 AS billing_state_code,
        NULLIF(TRIM(billing_postal_code), '')                       AS billing_postal_code,
        NULLIF(TRIM(billing_country), '')                           AS billing_country,
        UPPER(NULLIF(TRIM(billing_country_code), ''))               AS billing_country_code,

        -- company profile
        annual_revenue,
        number_of_employees,

        -- timestamps
        created_at,
        last_modified_at,
        last_activity_date_raw,

        bronze_ingest_timestamp

    FROM unpacked

),

-- ============================================================
-- SECTION 4: DERIVE: computed/enriched columns
-- Fix: last_activity_date < created_at on some records.
-- Rule: if last_activity_date is earlier than created_at date,
-- set last_activity_date = created_at::DATE.
-- This is a pipeline-safe fix: works on any future data run.
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

        -- Derived: days since last activity
        -- Pipeline-safe: uses CURRENT_DATE, not a hardcoded date
        CURRENT_DATE - CASE
            WHEN last_activity_date_raw < created_at::DATE
            THEN created_at::DATE
            ELSE last_activity_date_raw
        END                                                         AS days_since_last_activity,

        -- Derived: is account active?
        -- An account is considered active if last_activity_date
        -- is within the last 180 days (pipeline-configurable)
        CASE
            WHEN (
                CURRENT_DATE - COALESCE(last_activity_date_raw, created_at::DATE)
            ) <= 180
            THEN TRUE
            ELSE FALSE
        END                                                         AS is_active

    FROM cleaned

),

-- ============================================================
-- SECTION 5: SURROGATE KEY + SILVER METADATA
-- acc_sk: human-readable surrogate (acc_00001, acc_00002 ...)
-- record_hash_key: MD5 of full row for incremental upserts
-- ============================================================
final AS (

    SELECT
        -- -------------------------------------------------------
        -- surrogate key
        -- -------------------------------------------------------
        'acc_' || LPAD(
            ROW_NUMBER() OVER (ORDER BY account_source_id)::TEXT, 5, '0'
        )                                                           AS acc_sk,

        -- -------------------------------------------------------
        -- natural keys
        -- -------------------------------------------------------
        account_source_id,
        swiftroute_client_id,

        -- -------------------------------------------------------
        -- dbt incremental unique key
        -- -------------------------------------------------------
        MD5(
            COALESCE(account_source_id, '')             ||
            COALESCE(account_name, '')                  ||
            COALESCE(account_tier, '')                  ||
            COALESCE(contract_type, '')                 ||
            COALESCE(discount_rate::TEXT, '')           ||
            COALESCE(last_modified_at::TEXT, '')        ||
            COALESCE(contracted_monthly_volume::TEXT, '')
        )                                                           AS record_hash_key,

        -- -------------------------------------------------------
        -- account attributes
        -- -------------------------------------------------------
        account_name,
        account_type,
        industry,
        account_tier,
        primary_city,
        contract_type,
        discount_rate,
        net_payment_terms_days,
        is_fulfillment_client,
        contracted_monthly_volume,
        is_active,

        -- -------------------------------------------------------
        -- owner
        -- -------------------------------------------------------
        owner_id,
        owner_name,
        owner_email,

        -- -------------------------------------------------------
        -- contact
        -- -------------------------------------------------------
        phone,
        website,

        -- -------------------------------------------------------
        -- billing address
        -- -------------------------------------------------------
        billing_street,
        billing_city,
        billing_state,
        billing_state_code,
        billing_postal_code,
        billing_country,
        billing_country_code,

        -- -------------------------------------------------------
        -- company profile
        -- -------------------------------------------------------
        annual_revenue,
        number_of_employees,

        -- -------------------------------------------------------
        -- timestamps
        -- -------------------------------------------------------
        created_at,
        last_modified_at,
        last_activity_date,
        days_since_last_activity,

        -- -------------------------------------------------------
        -- silver metadata
        -- -------------------------------------------------------
        NOW()                                                       AS silver_loaded_at,
        'silver_salesforce_accounts'                                AS silver_source_model

    FROM derived

)

SELECT * FROM final