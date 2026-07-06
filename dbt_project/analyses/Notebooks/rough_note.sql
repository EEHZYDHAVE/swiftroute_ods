SELECT 
    *
from (
    select
    -- metadata columns added by the loader
    -- metadata columns added by the loader
    id                                              AS bronze_row_id,
    ingest_timestamp                                AS bronze_ingest_timestamp,
    source_file                                     AS bronze_source_file,

    -- core item identifiers
    raw_data ->> 'StockItemId'                      AS stock_item_id,
    raw_data ->> 'ItemNumber'                       AS item_number,
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

from bronze.linnworks_inventory

order by ingest_timestamp desc, bronze_row_id desc
) as linnworks_inventory

where item_title = 'Networked bifurcated process improvement';