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

SELECT
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
    raw_data ->> 'fkOrderId'                        AS reference_number,

    -- warehouse details
    raw_data ->> 'Location'                         AS location,
    raw_data ->> 'BinRack'                          AS bin_rack,

    -- dates
    (raw_data ->> 'Date')::timestamp                AS transaction_date,

    -- system note
    raw_data ->> '_note'                            AS system_note,

    -- raw data for reference
    raw_data

FROM bronze.linnworks_stock_transactions

ORDER BY ingest_timestamp DESC, bronze_row_id DESC


RAW DATA:
{
  "SKU": "RODR-C024",
  "Date": "2025-06-30T20:57:30.000Z",
  "_note": "Running balance must be reconstructed by replaying transactions",
  "BinRack": "BIN-16-16",
  "Location": "Denver Warehouse",
  "Quantity": -1,
  "ItemTitle": "Open-source intangible circuit",
  "fkOrderId": "LW23878258",
  "StockValue": 20.51,
  "fkStockItemId": "D9B24214-A189-9EDF-9F61-05C199B4B047",
  "TransactionNote": "Stock removed for a processed order",
  "TransactionType": "DISPATCH",
  "pkStockTransactionId": "6A0308CE-775D-540C-0E9B-932ABF1E7144"
}