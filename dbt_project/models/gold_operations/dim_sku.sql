-- ============================================================
-- model:        dim_sku
-- layer:        gold_operations (conformed dimension)
-- description:  Product/SKU dimension from Linnworks inventory.
--               Defines the physical goods handled by SwiftRoute
--               on behalf of fulfillment clients.
--
-- key facts:
--   - sku_key: normalised_sku (e.g. RODR-D009). This is the
--     canonical cross-system product identifier used in
--     fact_inventory_transaction. Normalised SKU is used
--     rather than stock_item_source_id because the inventory
--     duplicate resolution in silver established normalised_sku
--     as the authoritative product identity.
--   - Only surviving records (is_surviving_record = TRUE) are
--     included. Duplicate product master records resolved in
--     silver are excluded here to prevent double-counting in
--     fact tables.
--   - client_owner: the SwiftRoute client whose inventory
--     this SKU belongs to. Links to dim_client via
--     swiftroute_client_id.
--   - price: retail_price from Linnworks (selling price).
--   - dimensions and weight retained for logistics analysis.
--
-- materialized: table (conformed dimension, full rebuild
--               each run reflects current product master)
--
-- depends_on:   silver.silver_linnworks_inventory
-- ============================================================

{{
    config(
        materialized='table',
        schema='gold_operations'
    )
}}

-- ============================================================
-- SECTION 1: SOURCE
-- Filter to surviving records only to exclude duplicates
-- resolved during silver layer processing.
-- ============================================================
WITH inventory AS (

    SELECT
        normalised_sku,
        stock_item_source_id,
        inv_sk,
        item_sku_raw,
        item_title,
        barcode_number,
        category_name,
        package_group_name,
        cost_price,
        retail_price,
        weight_grams,
        width_cm,
        height_cm,
        depth_cm,
        is_composite_parent,
        is_variation_parent,
        swiftroute_client_id,
        swiftroute_client_name
    FROM {{ ref('silver_linnworks_inventory') }}
    WHERE is_surviving_record = TRUE

)

-- ============================================================
-- SECTION 2: FINAL SELECT
-- sku_key = normalised_sku (canonical product identifier).
-- ============================================================
SELECT
    -- -------------------------------------------------------
    -- primary key
    -- -------------------------------------------------------
    normalised_sku                                                  AS sku_key,

    -- -------------------------------------------------------
    -- source references
    -- -------------------------------------------------------
    stock_item_source_id,
    inv_sk,
    item_sku_raw                                                    AS sku_code_raw,

    -- -------------------------------------------------------
    -- product identity
    -- -------------------------------------------------------
    item_title                                                      AS sku_name,
    barcode_number,
    category_name,
    package_group_name,

    -- -------------------------------------------------------
    -- pricing
    -- -------------------------------------------------------
    retail_price                                                    AS price,
    cost_price,

    -- -------------------------------------------------------
    -- physical attributes
    -- -------------------------------------------------------
    weight_grams                                                    AS weight,
    width_cm,
    height_cm,
    depth_cm,

    -- -------------------------------------------------------
    -- flags
    -- -------------------------------------------------------
    is_composite_parent,
    is_variation_parent,

    -- -------------------------------------------------------
    -- client ownership
    -- -------------------------------------------------------
    swiftroute_client_id                                            AS client_owner,
    swiftroute_client_name                                          AS client_name

FROM inventory

ORDER BY normalised_sku