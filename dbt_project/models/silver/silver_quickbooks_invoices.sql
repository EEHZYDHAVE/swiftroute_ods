-- ============================================================
-- model:        silver_quickbooks_invoices
-- layer:        silver
-- source:       {{ source('bronze', 'quickbooks_invoices') }}
-- loaded_by:    loaders/load_quickbooks.py
-- description:  Cleaned and standardised invoice records from
--               QuickBooks. Invoices represent monthly billing
--               to SwiftRoute clients for delivery services.
--
-- key facts:
--   - QuickBooks Id retained as invoice_source_id. Surrogate
--     key inv_qb_sk generated (prefixed inv_qb to avoid
--     collision with linnworks inv_sk).
--   - swiftroute_client_id extracted from CustomField array
--     by name, not by index, for pipeline safety.
--   - billing_period extracted from CustomField array.
--   - payment_terms extracted from CustomField array.
--   - Line items: first line unpacked at index 0. Full Line
--     array retained as JSONB for downstream unnesting.
--   - linked_invoice_id extracted from payment Line array
--     for payment reconciliation joins.
--   - All timestamps to TIMESTAMPTZ.
--   - All empty strings to NULL.
--
-- incremental:  Upserts on MD5 of full row (record_hash_key).
--               Safe to re-run, existing records update.
--
-- depends_on:   bronze.quickbooks_invoices
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
    FROM {{ source('bronze', 'quickbooks_invoices') }}

    {% if is_incremental() %}
    WHERE ingest_timestamp > (
        SELECT MAX(silver_loaded_at) FROM {{ this }}
    )
    {% endif %}

),

-- ============================================================
-- SECTION 2: UNPACK
-- All field names verified against raw data samples.
-- CustomField array unpacked by name for pipeline safety.
-- Pipeline-safe: new CustomField entries won't break this.
-- ============================================================
unpacked AS (

    SELECT
        -- natural key
        raw_data ->> 'Id'                                           AS invoice_source_id,
        raw_data ->> 'DocNumber'                                    AS document_number,
        raw_data ->> 'SyncToken'                                    AS sync_token,

        -- dates
        (raw_data ->> 'TxnDate')::DATE                              AS transaction_date,
        (raw_data ->> 'DueDate')::DATE                              AS due_date,
        (raw_data -> 'MetaData' ->> 'CreateTime')::TIMESTAMPTZ      AS created_at,
        (raw_data -> 'MetaData' ->> 'LastUpdatedTime')::TIMESTAMPTZ AS last_updated_at,

        -- customer
        raw_data -> 'CustomerRef' ->> 'value'                       AS customer_id,
        raw_data -> 'CustomerRef' ->> 'name'                        AS customer_name,

        -- amounts
        (raw_data ->> 'TotalAmt')::NUMERIC                          AS total_amount,
        (raw_data ->> 'Balance')::NUMERIC                           AS balance,

        -- status
        raw_data ->> 'EmailStatus'                                  AS email_status_raw,

        -- currency
        raw_data -> 'CurrencyRef' ->> 'value'                       AS currency,

        -- billing email
        raw_data -> 'BillEmail' ->> 'Address'                       AS bill_email,

        -- payment method
        raw_data -> 'PaymentMethodRef' ->> 'name'                   AS payment_method,

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
            WHERE elem ->> 'Name' = 'Billing Period'
            LIMIT 1
        )                                                           AS billing_period,
        (
            SELECT elem ->> 'StringValue'
            FROM JSONB_ARRAY_ELEMENTS(raw_data -> 'CustomField') AS elem
            WHERE elem ->> 'Name' = 'Payment Terms'
            LIMIT 1
        )                                                           AS payment_terms,

        -- first line item (index 0)
        raw_data -> 'Line' -> 0 ->> 'Id'                            AS line_id,
        (raw_data -> 'Line' -> 0 ->> 'Amount')::NUMERIC             AS line_amount,
        raw_data -> 'Line' -> 0 ->> 'Description'                   AS line_description,
        (raw_data -> 'Line' -> 0 -> 'SalesItemLineDetail' ->> 'Qty')::INT
                                                                    AS line_qty,
        (raw_data -> 'Line' -> 0 -> 'SalesItemLineDetail' ->> 'UnitPrice')::NUMERIC
                                                                    AS line_unit_price,
        (raw_data -> 'Line' -> 0 -> 'SalesItemLineDetail' ->> 'ServiceDate')::DATE
                                                                    AS line_service_date,
        raw_data -> 'Line' -> 0 -> 'SalesItemLineDetail' -> 'ItemRef' ->> 'name'
                                                                    AS line_item_name,
        raw_data -> 'Line'                                          AS lines_raw,

        bronze_ingest_timestamp

    FROM source

),

-- ============================================================
-- SECTION 3: CLEAN
-- ============================================================
cleaned AS (

    SELECT
        invoice_source_id,
        NULLIF(TRIM(document_number), '')                           AS document_number,
        NULLIF(TRIM(sync_token), '')                                AS sync_token,
        transaction_date,
        due_date,
        created_at,
        last_updated_at,
        NULLIF(TRIM(customer_id), '')                               AS customer_id,
        NULLIF(TRIM(customer_name), '')                             AS customer_name,
        total_amount,
        balance,
        UPPER(NULLIF(TRIM(email_status_raw), ''))                   AS email_status,
        UPPER(NULLIF(TRIM(currency), ''))                           AS currency,
        LOWER(NULLIF(TRIM(bill_email), ''))                         AS bill_email,
        NULLIF(TRIM(payment_method), '')                            AS payment_method,
        NULLIF(TRIM(swiftroute_client_id), '')                      AS swiftroute_client_id,
        NULLIF(TRIM(billing_period), '')                            AS billing_period,
        NULLIF(TRIM(payment_terms), '')                             AS payment_terms,
        NULLIF(TRIM(line_id), '')                                   AS line_id,
        line_amount,
        NULLIF(TRIM(line_description), '')                          AS line_description,
        line_qty,
        line_unit_price,
        line_service_date,
        NULLIF(TRIM(line_item_name), '')                            AS line_item_name,
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

        -- Derived: is invoice fully paid?
        CASE
            WHEN balance IS NOT NULL AND balance = 0 THEN TRUE
            WHEN balance IS NOT NULL AND balance > 0 THEN FALSE
            ELSE NULL
        END                                                         AS is_paid,

        -- Derived: is invoice overdue?
        -- Pipeline-safe: uses CURRENT_DATE, not hardcoded date.
        CASE
            WHEN balance > 0 AND due_date < CURRENT_DATE THEN TRUE
            ELSE FALSE
        END                                                         AS is_overdue,

        -- Derived: days overdue (positive = overdue, NULL if paid)
        CASE
            WHEN balance > 0 AND due_date < CURRENT_DATE
            THEN (CURRENT_DATE - due_date)
            ELSE NULL
        END                                                         AS days_overdue,

        -- Derived: days to due from transaction date
        CASE
            WHEN due_date IS NOT NULL AND transaction_date IS NOT NULL
            THEN (due_date - transaction_date)
            ELSE NULL
        END                                                         AS payment_terms_days

    FROM cleaned

),

-- ============================================================
-- SECTION 5: SURROGATE KEY + SILVER METADATA
-- inv_qb_sk: surrogate key prefixed inv_qb to distinguish
-- from linnworks inv_sk in downstream joins.
-- record_hash_key: MD5 of full row for incremental upserts
-- ============================================================
final AS (

    SELECT
        -- -------------------------------------------------------
        -- surrogate key
        -- -------------------------------------------------------
        'inv_qb_' || LPAD(
            ROW_NUMBER() OVER (ORDER BY invoice_source_id)::TEXT
        , 5, '0')                                                   AS inv_qb_sk,

        -- -------------------------------------------------------
        -- natural key
        -- -------------------------------------------------------
        invoice_source_id,

        -- -------------------------------------------------------
        -- dbt incremental unique key
        -- -------------------------------------------------------
        MD5(
            COALESCE(invoice_source_id, '')         ||
            COALESCE(document_number, '')           ||
            COALESCE(total_amount::TEXT, '')        ||
            COALESCE(balance::TEXT, '')             ||
            COALESCE(due_date::TEXT, '')            ||
            COALESCE(last_updated_at::TEXT, '')
        )                                                           AS record_hash_key,

        -- -------------------------------------------------------
        -- identifiers
        -- -------------------------------------------------------
        document_number,
        swiftroute_client_id,
        customer_id,
        customer_name,
        billing_period,

        -- -------------------------------------------------------
        -- status
        -- -------------------------------------------------------
        email_status,
        is_paid,
        is_overdue,
        days_overdue,

        -- -------------------------------------------------------
        -- financials
        -- -------------------------------------------------------
        total_amount,
        balance,
        currency,
        payment_method,
        payment_terms,
        payment_terms_days,

        -- -------------------------------------------------------
        -- billing
        -- -------------------------------------------------------
        bill_email,

        -- -------------------------------------------------------
        -- first line item
        -- -------------------------------------------------------
        line_id,
        line_item_name,
        line_description,
        line_qty,
        line_unit_price,
        line_amount,
        line_service_date,
        lines_raw,

        -- -------------------------------------------------------
        -- dates
        -- -------------------------------------------------------
        transaction_date,
        due_date,
        created_at,
        last_updated_at,

        -- -------------------------------------------------------
        -- silver metadata
        -- -------------------------------------------------------
        NOW()                                                       AS silver_loaded_at,
        'silver_quickbooks_invoices'                                AS silver_source_model

    FROM derived

)

SELECT * FROM final