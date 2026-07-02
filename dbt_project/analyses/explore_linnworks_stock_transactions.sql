-- =============================================================================
-- analysis: explore_linnworks_stock_transactions.sql
-- purpose:  Unpack raw JSONB from bronze.linnworks_stock_transactions into
--           readable columns for exploratory review before writing silver model.
--
-- layer:    bronze (read only, no data is created or modified)
-- schema:   bronze
-- source:   bronze.linnworks_stock_transactions
--
-- usage:    Run via dbt Power User preview or psql session.
--           Not materialized, analysis files never create database objects.
-- =============================================================================

select
    -- metadata columns added by the loader
    id                                              as bronze_row_id,
    ingest_timestamp                                as bronze_ingest_timestamp,
    source_file                                     as bronze_source_file,

    -- core transaction identifiers
    raw_data ->> 'StockItemId'                      as stock_item_id,
    raw_data ->> 'SKU'                              as sku,
    raw_data ->> 'TransactionType'                  as transaction_type,

    -- quantities and values
    (raw_data ->> 'Quantity')::int                  as quantity,
    (raw_data ->> 'Price')::numeric                 as price,

    -- dates
    (raw_data ->> 'Date')::timestamp                as transaction_date,

    -- reference
    raw_data ->> 'Reference'                        as reference,
    raw_data ->> 'Note'                             as note,

    -- raw data for reference
    raw_data

from bronze.linnworks_stock_transactions

order by ingest_timestamp desc, bronze_row_id desc