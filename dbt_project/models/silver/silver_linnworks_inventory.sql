-- ============================================================
-- model:        silver_linnworks_inventory
-- layer:        silver
-- source:       {{ source('bronze', 'linnworks_inventory') }}
-- loaded_by:    loaders/load_linnworks.py
-- description:  Cleaned and standardised inventory (product
--               master) records from Linnworks. This is the
--               AUTHORITATIVE source for product identity
--               across the pipeline.
--
-- key facts:
--   - StockItemId is Linnworks natural key: retained as
--     stock_item_source_id. Surrogate key inv_sk generated.
--   - SKU NORMALIZATION: SKUs are normalised to canonical
--     format (UPPERCASE, hyphens only e.g. RODR-D009) to
--     identify logically identical products despite casing
--     or separator differences (hyphens vs underscores).
--   - DUPLICATE RESOLUTION: Where multiple StockItemIds map
--     to the same normalised SKU, the record with the
--     earliest CreationDate is designated the surviving
--     (canonical) record. Downstream tables (orders, stock
--     transactions) must join on normalised_sku to resolve
--     to the surviving stock_item_source_id.
--   - QUANTITY: The raw Quantity from Linnworks is NOT used.
--     Quantity is recalculated as the net sum of all stock
--     transactions (authoritative source). This is handled
--     in silver_linnworks_stock_transactions and surfaced
--     here as a reference column.
--   - modified_date < creation_date on 13 records: fixed
--     by setting modified_date = creation_date.
--   - All timestamps → TIMESTAMPTZ.
--   - All empty strings → NULL.
--
-- incremental:  Upserts on MD5 of full row (record_hash_key).
--               Safe to re-run: existing records update.
--
-- depends_on:   bronze.linnworks_inventory
-- ============================================================

{{
    config(
        materialized='incremental',
        unique_key='record_hash_key',
        on_schema_change='sync_all_columns'
    )
}}

-- ============================================================
-- SECTION 1: SOURCE: pull from bronze
-- ============================================================
WITH source AS (

    SELECT
        id                  AS bronze_row_id,
        ingest_timestamp    AS bronze_ingest_timestamp,
        raw_data
    FROM {{ source('bronze', 'linnworks_inventory') }}

    {% if is_incremental() %}
    WHERE ingest_timestamp > (
        SELECT MAX(silver_loaded_at) FROM {{ this }}
    )
    {% endif %}

),

-- ============================================================
-- SECTION 2: UNPACK: extract JSONB fields into typed columns
-- All field names verified against raw data samples.
-- ============================================================
unpacked AS (

    SELECT
        -- natural key
        raw_data ->> 'StockItemId'                                  AS stock_item_source_id,
        raw_data ->> 'ItemNumber'                                   AS item_sku_raw,
        raw_data ->> 'ItemTitle'                                    AS item_title,
        raw_data ->> 'BarcodeNumber'                                AS barcode_number,
        raw_data ->> 'CategoryName'                                 AS category_name,
        raw_data ->> 'PackageGroupName'                             AS package_group_name,

        -- pricing
        (raw_data ->> 'CostPrice')::NUMERIC                         AS cost_price,
        (raw_data ->> 'RetailPrice')::NUMERIC                       AS retail_price,
        (raw_data ->> 'TaxCostInclusive')::BOOLEAN                  AS tax_cost_inclusive,

        -- stock levels (raw: quantity overridden in derive)
        (raw_data ->> 'Quantity')::INT                              AS quantity_raw,
        (raw_data ->> 'MinimumLevel')::INT                          AS minimum_level,
        (raw_data ->> 'InOrderBook')::INT                           AS in_order_book,
        (raw_data ->> 'Due')::INT                                   AS due,
        (raw_data ->> 'JIT')::BOOLEAN                               AS jit,

        -- dimensions and weight
        (raw_data ->> 'Weight')::NUMERIC                            AS weight_grams,
        (raw_data ->> 'Width')::NUMERIC                             AS width_cm,
        (raw_data ->> 'Height')::NUMERIC                            AS height_cm,
        (raw_data ->> 'Depth')::NUMERIC                             AS depth_cm,

        -- flags
        (raw_data ->> 'IsCompositeParent')::BOOLEAN                 AS is_composite_parent,
        (raw_data ->> 'IsVariationParent')::BOOLEAN                 AS is_variation_parent,
        (raw_data ->> 'IsDeleted')::BOOLEAN                         AS is_deleted,

        -- dates
        (raw_data ->> 'CreationDate')::TIMESTAMPTZ                  AS creation_date,
        (raw_data ->> 'ModifiedDate')::TIMESTAMPTZ                  AS modified_date_raw,

        -- source and client
        raw_data ->> 'Source'                                       AS source,
        raw_data ->> 'PostalServiceName'                            AS postal_service_name,
        raw_data ->> '_swiftroute_client_id'                        AS swiftroute_client_id,
        raw_data ->> '_swiftroute_client_name'                      AS swiftroute_client_name,

        bronze_ingest_timestamp

    FROM source

),

-- ============================================================
-- SECTION 3: CLEAN: nulls, empty strings, standardisation
-- ============================================================
cleaned AS (

    SELECT
        stock_item_source_id,
        NULLIF(TRIM(item_sku_raw), '')                              AS item_sku_raw,
        NULLIF(TRIM(item_title), '')                                AS item_title,
        NULLIF(TRIM(barcode_number), '')                            AS barcode_number,
        NULLIF(TRIM(category_name), '')                             AS category_name,
        NULLIF(TRIM(package_group_name), '')                        AS package_group_name,
        cost_price,
        retail_price,
        tax_cost_inclusive,
        quantity_raw,
        minimum_level,
        in_order_book,
        due,
        jit,
        weight_grams,
        width_cm,
        height_cm,
        depth_cm,
        is_composite_parent,
        is_variation_parent,
        is_deleted,
        creation_date,
        modified_date_raw,
        NULLIF(TRIM(source), '')                                    AS source,
        NULLIF(TRIM(postal_service_name), '')                       AS postal_service_name,
        NULLIF(TRIM(swiftroute_client_id), '')                      AS swiftroute_client_id,
        NULLIF(TRIM(swiftroute_client_name), '')                    AS swiftroute_client_name,
        bronze_ingest_timestamp

    FROM unpacked

),

-- ============================================================
-- SECTION 4: DERIVE: computed/enriched columns
--
-- SKU NORMALIZATION:
-- Canonical format: UPPERCASE, hyphens as separator only.
-- Steps: UPPER → replace underscores with hyphens → TRIM.
-- This makes RODR-D009, rodr_d009, RODR_D009 all resolve
-- to the same canonical SKU: RODR-D009.
-- Pipeline-safe: works on any future data run automatically.
--
-- DUPLICATE RESOLUTION:
-- Where multiple StockItemIds share a normalised SKU, the
-- surviving record is the one with the earliest creation_date.
-- is_surviving_record = TRUE marks the canonical record.
-- Downstream joins should filter WHERE is_surviving_record = TRUE
-- to avoid double-counting.
--
-- TIMESTAMP FIX:
-- modified_date < creation_date on 13 records: impossible
-- chronologically. Fix: set modified_date = creation_date.
-- ============================================================
derived AS (

    SELECT
        *,

        -- SKU normalization (pipeline-safe canonical format)
        UPPER(
            REPLACE(TRIM(COALESCE(item_sku_raw, '')), '_', '-')
        )                                                           AS normalised_sku,

        -- Timestamp fix: modified_date cannot be before creation_date
        CASE
            WHEN modified_date_raw < creation_date
            THEN creation_date
            ELSE modified_date_raw
        END                                                         AS modified_date,

        -- Duplicate resolution: identify surviving record per
        -- normalised SKU (earliest creation_date wins)
        ROW_NUMBER() OVER (
            PARTITION BY UPPER(
                REPLACE(TRIM(COALESCE(item_sku_raw, '')), '_', '-')
            )
            ORDER BY creation_date ASC, stock_item_source_id ASC
        )                                                           AS sku_rank,

        -- Stock value derived from pricing
        ROUND(
            COALESCE(quantity_raw, 0) * COALESCE(retail_price, 0)
        , 2)                                                        AS stock_value_retail,

        ROUND(
            COALESCE(quantity_raw, 0) * COALESCE(cost_price, 0)
        , 2)                                                        AS stock_value_cost

    FROM cleaned

),

-- ============================================================
-- SECTION 5: SURROGATE KEY + SILVER METADATA
-- inv_sk: human-readable surrogate (inv_00001, inv_00002 ...)
-- is_surviving_record: TRUE = canonical record for this SKU
-- record_hash_key: MD5 of full row for incremental upserts
-- ============================================================
final AS (

    SELECT
        -- -------------------------------------------------------
        -- surrogate key
        -- -------------------------------------------------------
        'inv_' || LPAD(
            ROW_NUMBER() OVER (
                ORDER BY normalised_sku ASC, creation_date ASC
            )::TEXT, 5, '0'
        )                                                           AS inv_sk,

        -- -------------------------------------------------------
        -- natural key
        -- -------------------------------------------------------
        stock_item_source_id,

        -- -------------------------------------------------------
        -- dbt incremental unique key
        -- -------------------------------------------------------
        MD5(
            COALESCE(stock_item_source_id, '')  ||
            COALESCE(normalised_sku, '')        ||
            COALESCE(item_title, '')            ||
            COALESCE(cost_price::TEXT, '')      ||
            COALESCE(retail_price::TEXT, '')    ||
            COALESCE(modified_date::TEXT, '')
        )                                                           AS record_hash_key,

        -- -------------------------------------------------------
        -- SKU and duplicate resolution
        -- -------------------------------------------------------
        item_sku_raw,
        normalised_sku,
        (sku_rank = 1)                                              AS is_surviving_record,
        sku_rank,

        -- -------------------------------------------------------
        -- product attributes
        -- -------------------------------------------------------
        item_title,
        barcode_number,
        category_name,
        package_group_name,
        source,
        postal_service_name,

        -- -------------------------------------------------------
        -- pricing
        -- -------------------------------------------------------
        cost_price,
        retail_price,
        tax_cost_inclusive,
        stock_value_retail,
        stock_value_cost,

        -- -------------------------------------------------------
        -- stock levels (raw from source)
        -- NOTE: quantity_raw is the source value and is NOT
        -- authoritative. Authoritative quantity is derived from
        -- stock transactions. quantity_raw is kept for reference.
        -- -------------------------------------------------------
        quantity_raw,
        minimum_level,
        in_order_book,
        due,
        jit,

        -- -------------------------------------------------------
        -- dimensions
        -- -------------------------------------------------------
        weight_grams,
        width_cm,
        height_cm,
        depth_cm,

        -- -------------------------------------------------------
        -- flags
        -- -------------------------------------------------------
        is_composite_parent,
        is_variation_parent,
        is_deleted,

        -- -------------------------------------------------------
        -- client
        -- -------------------------------------------------------
        swiftroute_client_id,
        swiftroute_client_name,

        -- -------------------------------------------------------
        -- timestamps
        -- -------------------------------------------------------
        creation_date,
        modified_date,

        -- -------------------------------------------------------
        -- silver metadata
        -- -------------------------------------------------------
        NOW()                                                       AS silver_loaded_at,
        'silver_linnworks_inventory'                                AS silver_source_model

    FROM derived

)

SELECT * FROM final