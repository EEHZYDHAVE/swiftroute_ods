-- ============================================================
-- model:        silver_quickbooks_payments
-- layer:        silver
-- source:       {{ source('bronze', 'quickbooks_payments') }}
-- loaded_by:    loaders/load_quickbooks.py
-- description:  Cleaned and standardised payment records from
--               QuickBooks. Payments represent client settlement
--               of invoices raised by SwiftRoute.
--
-- key facts:
--   - QuickBooks Id retained as payment_source_id. Surrogate
--     key pmt_sk generated.
--   - linked_invoice_id extracted from Line array to enable
--     joins to silver_quickbooks_invoices for reconciliation.
--   - swiftroute_client_id and days_to_pay extracted from
--     CustomField array by name for pipeline safety.
--   - deposit_account_name retained for cash flow tracking.
--   - unapplied_amount: any amount not yet applied to an
--     invoice. Should be 0 for fully reconciled payments.
--   - All timestamps to TIMESTAMPTZ.
--   - All empty strings to NULL.
--
-- incremental:  Upserts on MD5 of full row (record_hash_key).
--               Safe to re-run, existing records update.
--
-- depends_on:   bronze.quickbooks_payments
--               silver.silver_quickbooks_invoices (for joins)
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
    FROM {{ source('bronze', 'quickbooks_payments') }}

    {% if is_incremental() %}
    WHERE ingest_timestamp > (
        SELECT MAX(silver_loaded_at) FROM {{ this }}
    )
    {% endif %}

),

-- ============================================================
-- SECTION 2: UNPACK
-- All field names verified against raw data samples.
-- CustomField and Line arrays unpacked by name and path
-- for pipeline safety.
-- ============================================================
unpacked AS (

    SELECT
        -- natural key
        raw_data ->> 'Id'                                           AS payment_source_id,
        raw_data ->> 'SyncToken'                                    AS sync_token,

        -- dates
        (raw_data ->> 'TxnDate')::DATE                              AS transaction_date,
        (raw_data -> 'MetaData' ->> 'CreateTime')::TIMESTAMPTZ      AS created_at,
        (raw_data -> 'MetaData' ->> 'LastUpdatedTime')::TIMESTAMPTZ AS last_updated_at,

        -- customer
        raw_data -> 'CustomerRef' ->> 'value'                       AS customer_id,
        raw_data -> 'CustomerRef' ->> 'name'                        AS customer_name,

        -- amounts
        (raw_data ->> 'TotalAmt')::NUMERIC                          AS total_amount,
        (raw_data ->> 'UnappliedAmt')::NUMERIC                      AS unapplied_amount,

        -- payment method
        raw_data -> 'PaymentMethodRef' ->> 'name'                   AS payment_method,

        -- deposit account
        raw_data -> 'DepositToAccountRef' ->> 'name'                AS deposit_account_name,

        -- currency
        raw_data -> 'CurrencyRef' ->> 'value'                       AS currency,

        -- process flag
        (raw_data ->> 'ProcessPayment')::BOOLEAN                    AS process_payment,

        -- linked invoice (from Line array, first entry)
        (raw_data -> 'Line' -> 0 ->> 'Amount')::NUMERIC             AS line_amount,
        raw_data -> 'Line' -> 0 -> 'LinkedTxn' -> 0 ->> 'TxnId'    AS linked_invoice_id,
        raw_data -> 'Line' -> 0 -> 'LinkedTxn' -> 0 ->> 'TxnType'  AS linked_txn_type,

        -- custom fields (unpacked by name for pipeline safety)
        (
            SELECT elem ->> 'StringValue'
            FROM JSONB_ARRAY_ELEMENTS(raw_data -> 'CustomField') AS elem
            WHERE elem ->> 'Name' = 'SwiftRoute Client ID'
            LIMIT 1
        )                                                           AS swiftroute_client_id,
        (
            SELECT elem ->> 'StringValue'
            FROM JSONB_ARRAY_ELEMENTS(raw_data -> 'CustomField') AS elem
            WHERE elem ->> 'Name' = 'Days to Pay'
            LIMIT 1
        )                                                           AS days_to_pay_raw,

        bronze_ingest_timestamp

    FROM source

),

-- ============================================================
-- SECTION 3: CLEAN
-- ============================================================
cleaned AS (

    SELECT
        payment_source_id,
        NULLIF(TRIM(sync_token), '')                                AS sync_token,
        transaction_date,
        created_at,
        last_updated_at,
        NULLIF(TRIM(customer_id), '')                               AS customer_id,
        NULLIF(TRIM(customer_name), '')                             AS customer_name,
        total_amount,
        unapplied_amount,
        UPPER(NULLIF(TRIM(payment_method), ''))                     AS payment_method,
        NULLIF(TRIM(deposit_account_name), '')                      AS deposit_account_name,
        UPPER(NULLIF(TRIM(currency), ''))                           AS currency,
        process_payment,
        line_amount,
        NULLIF(TRIM(linked_invoice_id), '')                         AS linked_invoice_id,
        NULLIF(TRIM(linked_txn_type), '')                           AS linked_txn_type,
        NULLIF(TRIM(swiftroute_client_id), '')                      AS swiftroute_client_id,
        (NULLIF(TRIM(days_to_pay_raw), ''))::INT                    AS days_to_pay,
        bronze_ingest_timestamp

    FROM unpacked

),

-- ============================================================
-- SECTION 4: DERIVE
-- ============================================================
derived AS (

    SELECT
        *,

        -- Derived: is payment fully applied to an invoice?
        CASE
            WHEN unapplied_amount IS NOT NULL AND unapplied_amount = 0
            THEN TRUE
            ELSE FALSE
        END                                                         AS is_fully_applied,

        -- Derived: payment method category for reporting
        CASE
            WHEN UPPER(payment_method) IN ('ACH', 'BANK_TRANSFER')
            THEN 'Bank Transfer'
            WHEN UPPER(payment_method) IN ('CREDIT_CARD', 'CREDITCARD')
            THEN 'Credit Card'
            WHEN UPPER(payment_method) = 'CHECK'
            THEN 'Check'
            ELSE INITCAP(COALESCE(payment_method, 'Unknown'))
        END                                                         AS payment_method_category

    FROM cleaned

),

-- ============================================================
-- SECTION 5: SURROGATE KEY + SILVER METADATA
-- pmt_sk: human-readable surrogate (pmt_00001, pmt_00002 ...)
-- record_hash_key: MD5 of full row for incremental upserts
-- ============================================================
final AS (

    SELECT
        -- -------------------------------------------------------
        -- surrogate key
        -- -------------------------------------------------------
        'pmt_' || LPAD(
            ROW_NUMBER() OVER (ORDER BY payment_source_id)::TEXT
        , 5, '0')                                                   AS pmt_sk,

        -- -------------------------------------------------------
        -- natural key
        -- -------------------------------------------------------
        payment_source_id,

        -- -------------------------------------------------------
        -- dbt incremental unique key
        -- -------------------------------------------------------
        MD5(
            COALESCE(payment_source_id, '')         ||
            COALESCE(total_amount::TEXT, '')        ||
            COALESCE(unapplied_amount::TEXT, '')    ||
            COALESCE(transaction_date::TEXT, '')    ||
            COALESCE(linked_invoice_id, '')         ||
            COALESCE(last_updated_at::TEXT, '')
        )                                                           AS record_hash_key,

        -- -------------------------------------------------------
        -- identifiers
        -- -------------------------------------------------------
        swiftroute_client_id,
        customer_id,
        customer_name,
        linked_invoice_id,
        linked_txn_type,

        -- -------------------------------------------------------
        -- payment details
        -- -------------------------------------------------------
        payment_method,
        payment_method_category,
        deposit_account_name,
        currency,
        process_payment,
        is_fully_applied,

        -- -------------------------------------------------------
        -- amounts
        -- -------------------------------------------------------
        total_amount,
        unapplied_amount,
        line_amount,

        -- -------------------------------------------------------
        -- timing
        -- -------------------------------------------------------
        days_to_pay,
        transaction_date,
        created_at,
        last_updated_at,

        -- -------------------------------------------------------
        -- silver metadata
        -- -------------------------------------------------------
        NOW()                                                       AS silver_loaded_at,
        'silver_quickbooks_payments'                                AS silver_source_model

    FROM derived

)

SELECT * FROM final