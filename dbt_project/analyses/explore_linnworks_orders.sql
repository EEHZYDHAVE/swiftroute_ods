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


RAW DATA:
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