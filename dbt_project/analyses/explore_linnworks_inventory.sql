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

SELECT
    id                                              AS bronze_row_id,
    ingest_timestamp                                AS bronze_ingest_timestamp,
    source_file                                     AS bronze_source_file,

    -- core item identifiers
    raw_data ->> 'StockItemId'                      AS stock_item_id,
    raw_data ->> 'ItemNumber'                       AS item_sku,
    raw_data ->> 'ItemTitle'                        AS item_title,
    raw_data ->> 'BarcodeNumber'                    AS barcode_number,
    raw_data ->> 'CategoryName'                     AS category_name,
    raw_data ->> 'PackageGroupName'                 AS package_group_name,

    -- pricing and costs
    (raw_data ->> 'CostPrice')::numeric             AS cost_price,
    (raw_data ->> 'RetailPrice')::numeric           AS retail_price,
    (raw_data ->> 'TaxCostInclusive')::boolean      AS tax_cost_inclusive,

    -- stock levels
    (raw_data ->> 'Quantity')::int                  AS quantity,
    (raw_data ->> 'MinimumLevel')::int              AS minimum_level,
    (raw_data ->> 'InOrderBook')::int               AS in_order_book,
    (raw_data ->> 'Due')::int                       AS due,
    (raw_data ->> 'JIT')::boolean                   AS jit,

    -- dimensions and weight
    (raw_data ->> 'Weight')::numeric                AS weight,
    (raw_data ->> 'Width')::numeric                 AS width,
    (raw_data ->> 'Height')::numeric                AS height,
    (raw_data ->> 'Depth')::numeric                 AS depth,

    -- flags
    (raw_data ->> 'IsCompositeParent')::boolean     AS is_composite_parent,
    (raw_data ->> 'IsVariationParent')::boolean     AS is_variation_parent,
    (raw_data ->> 'IsDeleted')::boolean             AS is_deleted,

    -- dates
    (raw_data ->> 'CreationDate')::timestamp        AS creation_date,
    (raw_data ->> 'ModifiedDate')::timestamp        AS modified_date,

    -- source and client info
    raw_data ->> 'Source'                           AS source,
    raw_data ->> 'PostalServiceName'                AS postal_service_name,
    raw_data ->> '_swiftroute_client_id'            AS swiftroute_client_id,
    raw_data ->> '_swiftroute_client_name'          AS swiftroute_client_name,

    raw_data
FROM bronze.linnworks_inventory


RAW DATA:
{
  "Due": 50,
  "JIT": false,
  "Depth": 16.7,
  "Width": 38.3,
  "Height": 22.5,
  "Source": "DIRECT",
  "Weight": 1466,
  "Quantity": 100,
  "CostPrice": 53.5,
  "IsDeleted": false,
  "ItemTitle": "Right-sized heuristic hardware",
  "ItemNumber": "PERE-A001",
  "InOrderBook": 4,
  "RetailPrice": 135.47,
  "StockItemId": "9505D692-6523-1D88-CB4E-8F451C9C6ECD",
  "CategoryName": "Outdoor Gear",
  "CreationDate": "2024-03-11T00:00:00.000Z",
  "MinimumLevel": 13,
  "ModifiedDate": "2024-12-22T00:00:00.000Z",
  "BarcodeNumber": "5189288929548",
  "PackageGroupName": "Standard",
  "TaxCostInclusive": false,
  "IsCompositeParent": false,
  "IsVariationParent": false,
  "PostalServiceName": "SwiftRoute Standard",
  "_swiftroute_client_id": "client_001",
  "_swiftroute_client_name": "Perez, Todd and Guerrero"
}