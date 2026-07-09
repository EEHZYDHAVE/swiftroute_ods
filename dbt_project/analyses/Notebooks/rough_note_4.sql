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
    -- metadata columns added by the loader
    -- metadata columns added by the loader
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

    -- raw data for reference
    raw_data

FROM bronze.linnworks_inventory

ORDER BY ingest_timestamp DESC, bronze_row_id DESC



Raw data:
{
  "Due": 31,
  "JIT": false,
  "Depth": 17.9,
  "Width": 10.1,
  "Height": 25.9,
  "Source": "DIRECT",
  "Weight": 757,
  "Quantity": 218,
  "CostPrice": 39.57,
  "IsDeleted": false,
  "ItemTitle": "Customer-focused uniform infrastructure",
  "ItemNumber": "STEV-E017",
  "InOrderBook": 19,
  "RetailPrice": 122.14,
  "StockItemId": "E87D4FCD-C537-BF99-C555-E9F19C761DC8",
  "CategoryName": "Pet Supplies",
  "CreationDate": "2024-06-16T00:00:00.000Z",
  "MinimumLevel": 21,
  "ModifiedDate": "2025-01-01T00:00:00.000Z",
  "BarcodeNumber": "7707357580736",
  "PackageGroupName": "Standard",
  "TaxCostInclusive": false,
  "IsCompositeParent": false,
  "IsVariationParent": false,
  "PostalServiceName": "SwiftRoute Standard",
  "_swiftroute_client_id": "client_011",
  "_swiftroute_client_name": "Stevens Ltd"
}




-- =============================================================================
-- analysis: explore_linnworks_orders.sql
-- purpose:  Unpack raw JSONB from bronze.linnworks_orders into readable
--           columns for exploratory review before writing the silver model.
--           Use this to identify data quality issues, null patterns,
--           data types, and transformation requirements.
--
-- layer:    bronze (read only, no data is created or modified)
-- schema:   bronze
-- source:   bronze.linnworks_orders (loaded by loaders/load_linnworks.py)
--
-- usage:    Run via dbt Power User preview or psql session.
--           Not materialized, analysis files never create database objects.
-- =============================================================================

SELECT
    -- metadata columns added by the loader
    id                                              AS bronze_row_id,
    ingest_timestamp                                AS bronze_ingest_timestamp,
    source_file                                     AS bronze_source_file,

    -- core order identifiers
    raw_data ->> 'pkOrderID'                        AS order_id,
    (raw_data ->> 'NumOrderId')::int                AS order_number,
    raw_data ->> 'ReferenceNum'                     AS reference_number,
    raw_data ->> 'ExternalReference'                AS external_reference,
    raw_data ->> 'SecondaryReference'               AS secondary_reference,

    -- channel and source
    raw_data ->> 'Channel'                          AS channel,
    raw_data ->> 'Source'                           AS source,
    raw_data ->> 'SubSource'                        AS sub_source,
    raw_data ->> 'SiteCode'                         AS site_code,
    raw_data ->> 'FulfilmentLocationName'           AS fulfilment_location,

    -- dates
    (raw_data ->> 'ReceivedDate')::timestamp        AS received_at,
    (raw_data ->> 'ProcessedOn')::timestamp         AS processed_at,
    (raw_data ->> 'DispatchedOn')::timestamp        AS dispatched_at,

    -- customer
    raw_data ->> 'CustomerName'                     AS customer_name,
    raw_data ->> 'CustomerEmail'                    AS customer_email,

    -- shipping address
    raw_data -> 'Address' ->> 'FullName'            AS shipping_full_name,
    raw_data -> 'Address' ->> 'Company'             AS shipping_company,
    raw_data -> 'Address' ->> 'Address1'            AS shipping_address_1,
    raw_data -> 'Address' ->> 'Address2'            AS shipping_address_2,
    raw_data -> 'Address' ->> 'City'                AS shipping_city,
    raw_data -> 'Address' ->> 'Region'              AS shipping_region,
    raw_data -> 'Address' ->> 'PostCode'            AS shipping_postcode,
    raw_data -> 'Address' ->> 'Country'             AS shipping_country,
    raw_data -> 'Address' ->> 'CountryCode'         AS shipping_country_code,
    raw_data -> 'Address' ->> 'Phone'               AS shipping_phone,

    -- financials
    (raw_data ->> 'SubTotal')::numeric              AS subtotal,
    (raw_data ->> 'PostalServiceCost')::numeric     AS postal_service_cost,
    (raw_data ->> 'TotalCharge')::numeric           AS total_charge,
    (raw_data ->> 'TaxAmount')::numeric             AS tax_amount,
    raw_data ->> 'Currency'                         AS currency,
    raw_data ->> 'PaymentMethod'                    AS payment_method,
    raw_data ->> 'PaymentStatus'                    AS payment_status,

    -- general info
    (raw_data -> 'GeneralInfo' ->> 'Status')::int   AS order_status,
    (raw_data -> 'GeneralInfo' ->> 'LockForShipping')::boolean AS lock_for_shipping,
    (raw_data -> 'GeneralInfo' ->> 'Marker')::int   AS marker,
    raw_data -> 'GeneralInfo' ->> 'Notes'           AS general_notes,

    -- shipping info
    raw_data -> 'ShippingInfo' ->> 'PostalServiceName' AS postal_service_name,
    raw_data -> 'ShippingInfo' ->> 'TrackingNumber'    AS tracking_number,
    raw_data -> 'ShippingInfo' ->> 'Vendor'            AS shipping_vendor,
    raw_data -> 'ShippingInfo' ->> 'PostalServiceCode' AS postal_service_code,

    -- items (first item example, can be unnested for full array)
    raw_data -> 'Items' -> 0 ->> 'StockItemId'      AS item_stock_item_id,
    raw_data -> 'Items' -> 0 ->> 'SKU'              AS item_sku,
    raw_data -> 'Items' -> 0 ->> 'ItemTitle'        AS item_title,
    (raw_data -> 'Items' -> 0 ->> 'Quantity')::int  AS item_quantity,
    (raw_data -> 'Items' -> 0 ->> 'UnitCost')::numeric AS item_unit_cost,
    (raw_data -> 'Items' -> 0 ->> 'PricePerUnit')::numeric AS item_price_per_unit,
    (raw_data -> 'Items' -> 0 ->> 'LineTotal')::numeric AS item_line_total,
    (raw_data -> 'Items' -> 0 ->> 'Weight')::numeric AS item_weight,
    (raw_data -> 'Items' -> 0 ->> 'IsComposite')::boolean AS item_is_composite,
    raw_data -> 'Items' -> 0 ->> 'BinRack'          AS item_bin_rack,

    -- client integration fields
    raw_data ->> '_swiftroute_client_id'            AS swiftroute_client_id,
    raw_data ->> '_swiftroute_client_name'          AS swiftroute_client_name,
    (raw_data ->> '_swiftroute_pick_duration_mins')::int AS swiftroute_pick_duration_mins,

    -- raw data for reference
    raw_data

FROM bronze.linnworks_orders

ORDER BY ingest_timestamp DESC, bronze_row_id DESC


Raw data:
{
  "Items": [
    {
      "SKU": "DYER-C026",
      "Weight": 441,
      "BinRack": "BIN-04-09",
      "Quantity": 3,
      "UnitCost": 46.37,
      "ItemTitle": "Diverse impactful moratorium",
      "LineTotal": 504.24,
      "IsComposite": false,
      "StockItemId": "9A8F6851-508B-CBBB-569B-E3523696DE41",
      "PricePerUnit": 168.08
    }
  ],
  "Source": "AMAZON",
  "Address": {
    "City": "South Andrew",
    "Phone": "001-665-904-1843",
    "Region": "Maine",
    "Company": "",
    "Country": "United States",
    "Address1": "1118 Baker Shoals",
    "Address2": "",
    "FullName": "Kyle Barber",
    "PostCode": "00552",
    "CountryCode": "US"
  },
  "Channel": "AMAZON",
  "Currency": "USD",
  "SiteCode": "DENVER-WH",
  "SubTotal": 504.24,
  "SubSource": "Dyer-Reeves",
  "TaxAmount": 41.08,
  "pkOrderID": "1817B0BF-D4E1-CD79-92A3-EE695A82916A",
  "NumOrderId": 45887,
  "GeneralInfo": {
    "Notes": "",
    "Marker": 0,
    "Status": 3,
    "LockForShipping": false
  },
  "ProcessedOn": "2025-06-30T17:24:41.000Z",
  "TotalCharge": 513.48,
  "CustomerName": "Kayla Delgado",
  "DispatchedOn": "2025-06-30T17:41:41.000Z",
  "ReceivedDate": "2025-06-30T16:34:41.000Z",
  "ReferenceNum": "LW95101785",
  "ShippingInfo": {
    "Vendor": "SwiftRoute Logistics",
    "TrackingNumber": "SR1541960691",
    "PostalServiceCode": "SR-ND",
    "PostalServiceName": "SwiftRoute Next Day"
  },
  "CustomerEmail": "jim01@example.net",
  "PaymentMethod": "STRIPE",
  "PaymentStatus": "PAID",
  "ExternalReference": "AMAZON-631769",
  "PostalServiceCost": 9.24,
  "SecondaryReference": "",
  "_swiftroute_client_id": "client_004",
  "FulfilmentLocationName": "Denver Warehouse",
  "_swiftroute_client_name": "Dyer-Reeves",
  "_swiftroute_pick_duration_mins": 8
}



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

FROM {{ source('bronze', 'linnworks_stock_transactions') }}

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