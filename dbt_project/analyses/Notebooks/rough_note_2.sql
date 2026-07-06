select driver_id
from (
   select
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

from bronze.linnworks_orders

order by ingest_timestamp desc, bronze_row_id desc
) as linnworks_orders
