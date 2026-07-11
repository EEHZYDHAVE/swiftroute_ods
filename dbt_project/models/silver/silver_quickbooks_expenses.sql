-- ============================================================
-- model:        silver_quickbooks_expenses
-- layer:        silver
-- source:       {{ source('bronze', 'quickbooks_expenses') }}
-- loaded_by:    loaders/load_quickbooks.py
-- description:  Cleaned and standardised expense records from
--               QuickBooks. Expenses represent operational
--               costs incurred by SwiftRoute (fuel, supplies,
--               vehicle maintenance, warehouse costs, etc).
--
-- key facts:
--   - QuickBooks Id retained as expense_source_id. Surrogate
--     key exp_sk generated.
--   - vendor details extracted from EntityRef nested object.
--   - account details extracted from AccountRef nested object.
--   - First line item unpacked at index 0. Full Line array
--     retained as JSONB for downstream unnesting.
--   - Line account details extracted for granular cost
--     categorisation at line level.
--   - All timestamps to TIMESTAMPTZ.
--   - All empty strings to NULL.
--
-- incremental:  Upserts on MD5 of full row (record_hash_key).
--               Safe to re-run, existing records update.
--
-- depends_on:   bronze.quickbooks_expenses
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
    FROM {{ source('bronze', 'quickbooks_expenses') }}

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
        raw_data ->> 'Id'                                           AS expense_source_id,
        raw_data ->> 'SyncToken'                                    AS sync_token,

        -- dates
        (raw_data ->> 'TxnDate')::DATE                              AS transaction_date,
        (raw_data -> 'MetaData' ->> 'CreateTime')::TIMESTAMPTZ      AS created_at,
        (raw_data -> 'MetaData' ->> 'LastUpdatedTime')::TIMESTAMPTZ AS last_updated_at,

        -- vendor
        raw_data -> 'EntityRef' ->> 'value'                         AS vendor_id,
        raw_data -> 'EntityRef' ->> 'name'                          AS vendor_name,
        raw_data -> 'EntityRef' ->> 'type'                          AS vendor_type,

        -- account
        raw_data -> 'AccountRef' ->> 'value'                        AS account_id,
        raw_data -> 'AccountRef' ->> 'name'                         AS account_name,

        -- amounts
        (raw_data ->> 'TotalAmt')::NUMERIC                          AS total_amount,

        -- payment details
        raw_data ->> 'PaymentType'                                  AS payment_type_raw,
        raw_data ->> 'PrivateNote'                                  AS private_note_raw,

        -- currency
        raw_data -> 'CurrencyRef' ->> 'value'                       AS currency,

        -- first line item (index 0)
        raw_data -> 'Line' -> 0 ->> 'Id'                            AS line_id,
        (raw_data -> 'Line' -> 0 ->> 'Amount')::NUMERIC             AS line_amount,
        raw_data -> 'Line' -> 0 ->> 'DetailType'                    AS line_detail_type,
        raw_data -> 'Line' -> 0 ->> 'Description'                   AS line_description,
        raw_data -> 'Line' -> 0
            -> 'AccountBasedExpenseLineDetail'
            -> 'AccountRef' ->> 'value'                             AS line_account_id,
        raw_data -> 'Line' -> 0
            -> 'AccountBasedExpenseLineDetail'
            -> 'AccountRef' ->> 'name'                              AS line_account_name,
        raw_data -> 'Line' -> 0
            -> 'AccountBasedExpenseLineDetail'
            ->> 'BillableStatus'                                    AS line_billable_status,
        raw_data -> 'Line'                                          AS lines_raw,

        bronze_ingest_timestamp

    FROM source

),

-- ============================================================
-- SECTION 3: CLEAN
-- ============================================================
cleaned AS (

    SELECT
        expense_source_id,
        NULLIF(TRIM(sync_token), '')                                AS sync_token,
        transaction_date,
        created_at,
        last_updated_at,
        NULLIF(TRIM(vendor_id), '')                                 AS vendor_id,
        NULLIF(TRIM(vendor_name), '')                               AS vendor_name,
        INITCAP(NULLIF(TRIM(vendor_type), ''))                      AS vendor_type,
        NULLIF(TRIM(account_id), '')                                AS account_id,
        NULLIF(TRIM(account_name), '')                              AS account_name,
        total_amount,
        INITCAP(NULLIF(TRIM(payment_type_raw), ''))                 AS payment_type,
        NULLIF(TRIM(private_note_raw), '')                          AS private_note,
        UPPER(NULLIF(TRIM(currency), ''))                           AS currency,
        NULLIF(TRIM(line_id), '')                                   AS line_id,
        line_amount,
        NULLIF(TRIM(line_detail_type), '')                          AS line_detail_type,
        NULLIF(TRIM(line_description), '')                          AS line_description,
        NULLIF(TRIM(line_account_id), '')                           AS line_account_id,
        NULLIF(TRIM(line_account_name), '')                         AS line_account_name,
        INITCAP(NULLIF(TRIM(line_billable_status), ''))             AS line_billable_status,
        lines_raw,
        bronze_ingest_timestamp

    FROM unpacked

),

-- ============================================================
-- SECTION 4: DERIVE
-- ============================================================
derived AS (

    SELECT
        *,

        -- Derived: expense category from account name
        -- Maps account names to operational cost categories
        -- for reporting. Pipeline-safe: ILIKE pattern matching
        -- handles minor naming variations in future data runs.
        CASE
            WHEN account_name ILIKE '%fuel%'
            OR account_name ILIKE '%gas%'           THEN 'Fuel'
            WHEN account_name ILIKE '%vehicle%'
            OR account_name ILIKE '%maintenance%'   THEN 'Vehicle Maintenance'
            WHEN account_name ILIKE '%warehouse%'
            OR account_name ILIKE '%storage%'       THEN 'Warehouse'
            WHEN account_name ILIKE '%insurance%'   THEN 'Insurance'
            WHEN account_name ILIKE '%supplies%'    THEN 'Supplies'
            WHEN account_name ILIKE '%payroll%'
            OR account_name ILIKE '%salary%'        THEN 'Payroll'
            WHEN account_name ILIKE '%software%'
            OR account_name ILIKE '%subscription%'  THEN 'Software'
            ELSE 'Other'
        END                                                         AS expense_category,

        -- Derived: is expense billable to a client?
        CASE
            WHEN UPPER(line_billable_status) = 'BILLABLE' THEN TRUE
            ELSE FALSE
        END                                                         AS is_billable

    FROM cleaned

),

-- ============================================================
-- SECTION 5: SURROGATE KEY + SILVER METADATA
-- exp_sk: human-readable surrogate (exp_00001, exp_00002 ...)
-- record_hash_key: MD5 of full row for incremental upserts
-- ============================================================
final AS (

    SELECT
        -- -------------------------------------------------------
        -- surrogate key
        -- -------------------------------------------------------
        'exp_' || LPAD(
            ROW_NUMBER() OVER (ORDER BY expense_source_id)::TEXT
        , 5, '0')                                                   AS exp_sk,

        -- -------------------------------------------------------
        -- natural key
        -- -------------------------------------------------------
        expense_source_id,

        -- -------------------------------------------------------
        -- dbt incremental unique key
        -- -------------------------------------------------------
        MD5(
            COALESCE(expense_source_id, '')         ||
            COALESCE(total_amount::TEXT, '')        ||
            COALESCE(transaction_date::TEXT, '')    ||
            COALESCE(vendor_id, '')                 ||
            COALESCE(account_id, '')                ||
            COALESCE(last_updated_at::TEXT, '')
        )                                                           AS record_hash_key,

        -- -------------------------------------------------------
        -- vendor
        -- -------------------------------------------------------
        vendor_id,
        vendor_name,
        vendor_type,

        -- -------------------------------------------------------
        -- account and category
        -- -------------------------------------------------------
        account_id,
        account_name,
        expense_category,

        -- -------------------------------------------------------
        -- payment
        -- -------------------------------------------------------
        payment_type,
        currency,
        is_billable,

        -- -------------------------------------------------------
        -- amounts
        -- -------------------------------------------------------
        total_amount,

        -- -------------------------------------------------------
        -- first line item
        -- -------------------------------------------------------
        line_id,
        line_detail_type,
        line_account_id,
        line_account_name,
        line_description,
        line_amount,
        line_billable_status,
        lines_raw,

        -- -------------------------------------------------------
        -- notes
        -- -------------------------------------------------------
        private_note,

        -- -------------------------------------------------------
        -- dates
        -- -------------------------------------------------------
        transaction_date,
        created_at,
        last_updated_at,

        -- -------------------------------------------------------
        -- silver metadata
        -- -------------------------------------------------------
        NOW()                                                       AS silver_loaded_at,
        'silver_quickbooks_expenses'                                AS silver_source_model

    FROM derived

)

SELECT * FROM final