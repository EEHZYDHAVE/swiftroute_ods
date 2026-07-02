-- =============================================================================
-- analysis: explore_quickbooks_payments.sql
-- purpose:  Unpack raw JSONB from bronze.quickbooks_payments into readable
--           columns for exploratory review before writing the silver model.
--
-- layer:    bronze (read only, no data is created or modified)
-- schema:   bronze
-- source:   bronze.quickbooks_payments (loaded by loaders/load_quickbooks.py)
--
-- usage:    Run via dbt Power User preview or psql session.
--           Not materialized, analysis files never create database objects.
-- =============================================================================

select
    -- metadata columns added by the loader
    id                                              as bronze_row_id,
    ingest_timestamp                                as bronze_ingest_timestamp,
    source_file                                     as bronze_source_file,

    -- core payment identifiers
    raw_data ->> 'Id'                               as payment_id,
    raw_data ->> 'domain'                           as domain,

    -- dates
    (raw_data ->> 'TxnDate')::date                  as transaction_date,

    -- customer
    raw_data -> 'CustomerRef' ->> 'value'           as customer_id,
    raw_data -> 'CustomerRef' ->> 'name'            as customer_name,

    -- amounts
    (raw_data ->> 'TotalAmt')::numeric              as total_amount,
    (raw_data ->> 'UnappliedAmt')::numeric          as unapplied_amount,

    -- payment method
    raw_data -> 'PaymentMethodRef' ->> 'value'      as payment_method_id,
    raw_data -> 'PaymentMethodRef' ->> 'name'       as payment_method,

    -- currency
    raw_data -> 'CurrencyRef' ->> 'value'           as currency,

    -- raw data for reference
    raw_data

from bronze.quickbooks_payments

order by ingest_timestamp desc, bronze_row_id desc