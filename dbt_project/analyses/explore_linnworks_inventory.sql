-- =============================================================================
-- analysis: explore_linnworks_inventory.sql
-- purpose:  Unpack raw JSONB from bronze.linnworks_inventory into readable
--           columns for exploratory review before writing the silver model.
--
-- layer:    bronze (read only, no data is created or modified)
-- schema:   bronze
-- source:   bronze.linnworks_inventory (loaded by loaders/load_linnworks.py)
--
-- usage:    Run via dbt Power User preview or psql session.
--           Not materialized, analysis files never create database objects.
-- =============================================================================

select
    -- metadata columns added by the loader
    id                                              as bronze_row_id,
    ingest_timestamp                                as bronze_ingest_timestamp,
    source_file                                     as bronze_source_file,

    -- core item identifiers
    raw_data ->> 'SKU'                              as sku,
    raw_data ->> 'ItemTitle'                        as item_title,
    raw_data ->> 'StockItemId'                      as stock_item_id,
    raw_data ->> 'CategoryName'                     as category_name,

    -- stock levels
    (raw_data ->> 'StockLevel')::int                as stock_level,
    (raw_data ->> 'StockValue')::numeric            as stock_value,
    (raw_data ->> 'MinimumLevel')::int              as minimum_level,

    -- pricing
    (raw_data ->> 'RetailPrice')::numeric           as retail_price,
    (raw_data ->> 'PurchasePrice')::numeric         as purchase_price,

    -- raw data for reference
    raw_data

from bronze.linnworks_inventory

order by ingest_timestamp desc, bronze_row_id desc