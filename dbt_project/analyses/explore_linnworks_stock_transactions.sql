-- =============================================================================
-- analysis: explore_linnworks_stock_transactions.sql
-- purpose:  Unpack raw JSONB from bronze.linnworks_stock_transactions into
--           readable columns for exploratory review before writing silver model.
--
-- layer:    bronze (read only, no data is created or modified)
-- schema:   bronze
-- source:   source('bronze', 'linnworks_stock_transactions')
--
-- usage:    Run via dbt Power User preview or psql session.
--           Not materialized, analysis files never create database objects.
-- =============================================================================

select
    -- metadata columns added by the loader
    id                                              AS bronze_row_id,
    ingest_timestamp                                AS bronze_ingest_timestamp,
    source_file                                     AS bronze_source_file,

    -- core transaction identifiers
    raw_data ->> 'pkStockTransactionId'             AS stock_transaction_id,
    raw_data ->> 'fkStockItemId'                    AS stock_item_id,
    raw_data ->> 'SKU'                              AS sku,
    raw_data ->> 'ItemTitle'                        AS item_title,

    -- transaction details
    raw_data ->> 'TransactionType'                  AS transaction_type,
    raw_data ->> 'TransactionNote'                  AS transaction_note,

    -- quantities and values
    (raw_data ->> 'Quantity')::int                  AS quantity,
    (raw_data ->> 'StockValue')::numeric            AS stock_value,

    -- order linkage
    raw_data ->> 'fkOrderId'                        AS order_id,

    -- warehouse details
    raw_data ->> 'Location'                         AS location,
    raw_data ->> 'BinRack'                          AS bin_rack,

    -- dates
    (raw_data ->> 'Date')::timestamp                AS transaction_date,

    -- system note
    raw_data ->> '_note'                            AS system_note,

    -- raw data for reference
    raw_data

from {{ source('bronze', 'linnworks_stock_transactions') }}

order by ingest_timestamp desc, bronze_row_id desc
limit 20