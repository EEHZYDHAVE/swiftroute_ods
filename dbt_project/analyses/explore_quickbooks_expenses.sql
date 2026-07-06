-- =============================================================================
-- analysis: explore_quickbooks_expenses.sql
-- purpose:  Unpack raw JSONB from bronze.quickbooks_expenses into readable
--           columns for exploratory review before writing the silver model.
--
-- layer:    bronze (read only, no data is created or modified)
-- schema:   bronze
-- source:   bronze.quickbooks_expenses (loaded by loaders/load_quickbooks.py)
--
-- usage:    Run via dbt Power User preview or psql session.
--           Not materialized, analysis files never create database objects.
-- =============================================================================

SELECT
    -- metadata columns added by the loader
    id                                              AS bronze_row_id,
    ingest_timestamp                                AS bronze_ingest_timestamp,
    source_file                                     AS bronze_source_file,

    -- core expense identifiers
    raw_data ->> 'Id'                               AS expense_id,
    raw_data ->> 'domain'                           AS domain,
    raw_data ->> 'SyncToken'                        AS sync_token,

    -- dates
    (raw_data ->> 'TxnDate')::date                  AS transaction_date,
    (raw_data -> 'MetaData' ->> 'CreateTime')::timestamp     AS created_at,
    (raw_data -> 'MetaData' ->> 'LastUpdatedTime')::timestamp AS last_updated_at,

    -- vendor
    raw_data -> 'EntityRef' ->> 'value'             AS vendor_id,
    raw_data -> 'EntityRef' ->> 'name'              AS vendor_name,
    raw_data -> 'EntityRef' ->> 'type'              AS vendor_type,

    -- account
    raw_data -> 'AccountRef' ->> 'value'            AS account_id,
    raw_data -> 'AccountRef' ->> 'name'             AS account_name,

    -- amounts
    (raw_data ->> 'TotalAmt')::numeric              AS total_amount,

    -- payment type
    raw_data ->> 'PaymentType'                      AS payment_type,

    -- currency
    raw_data -> 'CurrencyRef' ->> 'value'           AS currency,

    -- private note
    raw_data ->> 'PrivateNote'                      AS private_note,

    -- line item (first line example, can unnest for full array)
    raw_data -> 'Line' -> 0 ->> 'Id'                AS line_id,
    (raw_data -> 'Line' -> 0 ->> 'Amount')::numeric AS line_amount,
    raw_data -> 'Line' -> 0 ->> 'DetailType'        AS line_detail_type,
    raw_data -> 'Line' -> 0 ->> 'Description'       AS line_description,
    raw_data -> 'Line' -> 0 -> 'AccountBasedExpenseLineDetail' -> 'AccountRef' ->> 'value' AS line_account_id,
    raw_data -> 'Line' -> 0 -> 'AccountBasedExpenseLineDetail' -> 'AccountRef' ->> 'name' AS line_account_name,
    raw_data -> 'Line' -> 0 -> 'AccountBasedExpenseLineDetail' ->> 'BillableStatus' AS line_billable_status,

    -- raw data for reference
    raw_data

FROM bronze.quickbooks_expenses
ORDER BY ingest_timestamp DESC, bronze_row_id DESC;