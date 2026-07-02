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

select
    -- metadata columns added by the loader
    id                                              as bronze_row_id,
    ingest_timestamp                                as bronze_ingest_timestamp,
    source_file                                     as bronze_source_file,

    -- core expense identifiers
    raw_data ->> 'Id'                               as expense_id,
    raw_data ->> 'domain'                           as domain,

    -- dates
    (raw_data ->> 'TxnDate')::date                  as transaction_date,

    -- vendor
    raw_data -> 'EntityRef' ->> 'value'             as vendor_id,
    raw_data -> 'EntityRef' ->> 'name'              as vendor_name,

    -- account
    raw_data -> 'AccountRef' ->> 'value'            as account_id,
    raw_data -> 'AccountRef' ->> 'name'             as account_name,

    -- amounts
    (raw_data ->> 'TotalAmt')::numeric              as total_amount,

    -- payment type
    raw_data ->> 'PaymentType'                      as payment_type,

    -- currency
    raw_data -> 'CurrencyRef' ->> 'value'           as currency,

    -- raw data for reference
    raw_data

from bronze.quickbooks_expenses

order by ingest_timestamp desc, bronze_row_id desc