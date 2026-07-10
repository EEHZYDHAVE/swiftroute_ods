-- ============================================================
-- model:        silver_linnworks_stock_transactions
-- layer:        silver
-- source:       {{ source('bronze', 'linnworks_stock_transactions') }}
-- loaded_by:    loaders/load_linnworks.py
-- description:  Cleaned and standardised stock transaction
--               records from Linnworks. This is the AUTHORITATIVE
--               source for inventory movements across the pipeline.
--               Stock quantities in silver_linnworks_inventory
--               are derived from the net sum of these transactions.
--
-- key facts:
--   - pkStockTransactionId is the natural key: retained as
--     transaction_source_id. Surrogate key txn_sk generated.
--   - SKU normalization applied (same canonical format as
--     silver_linnworks_inventory: UPPER, hyphens only).
--   - fkStockItemId resolved to surviving stock_item_source_id
--     via join to silver_linnworks_inventory on normalised_sku.
--     This corrects references that pointed to duplicate
--     (non-surviving) inventory records.
--   - Negative quantities represent stock OUT (DISPATCH).
--     Positive quantities represent stock IN (RECEIPT etc.).
--   - Running balance NOT stored here — must be reconstructed
--     by replaying transactions in date order. This is by
--     design (append-only bronze, authoritative ledger).
--   - All timestamps → TIMESTAMPTZ.
--   - All empty strings → NULL.
--
-- incremental:  Upserts on MD5 of full row (record_hash_key).
--               Safe to re-run: existing records update.
--
-- depends_on:   bronze.linnworks_stock_transactions
--               silver.silver_linnworks_inventory
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
    FROM {{ source('bronze', 'linnworks_stock_transactions') }}

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
        raw_data ->> 'pkStockTransactionId'                         AS transaction_source_id,

        -- stock item reference (may point to duplicate record)
        raw_data ->> 'fkStockItemId'                                AS stock_item_id_raw,
        raw_data ->> 'SKU'                                          AS sku_raw,
        raw_data ->> 'ItemTitle'                                    AS item_title,

        -- transaction details
        raw_data ->> 'TransactionType'                              AS transaction_type_raw,
        raw_data ->> 'TransactionNote'                              AS transaction_note_raw,

        -- quantities and values
        (raw_data ->> 'Quantity')::INT                              AS quantity,
        (raw_data ->> 'StockValue')::NUMERIC                        AS stock_value,

        -- order linkage
        raw_data ->> 'fkOrderId'                                    AS order_reference_number,

        -- warehouse details
        raw_data ->> 'Location'                                     AS location,
        raw_data ->> 'BinRack'                                      AS bin_rack,

        -- date
        (raw_data ->> 'Date')::TIMESTAMPTZ                          AS transaction_date,

        -- system note (known quirk documentation)
        raw_data ->> '_note'                                        AS system_note,

        bronze_ingest_timestamp

    FROM source

),

-- ============================================================
-- SECTION 3: CLEAN: nulls, empty strings, standardisation
-- ============================================================
cleaned AS (

    SELECT
        transaction_source_id,
        NULLIF(TRIM(stock_item_id_raw), '')                         AS stock_item_id_raw,
        NULLIF(TRIM(sku_raw), '')                                   AS sku_raw,
        NULLIF(TRIM(item_title), '')                                AS item_title,
        UPPER(NULLIF(TRIM(transaction_type_raw), ''))               AS transaction_type,
        NULLIF(TRIM(transaction_note_raw), '')                      AS transaction_note,
        quantity,
        stock_value,
        NULLIF(TRIM(order_reference_number), '')                    AS order_reference_number,
        NULLIF(TRIM(location), '')                                  AS location,
        NULLIF(TRIM(bin_rack), '')                                  AS bin_rack,
        transaction_date,
        NULLIF(TRIM(system_note), '')                               AS system_note,
        bronze_ingest_timestamp

    FROM unpacked

),

-- ============================================================
-- SECTION 4: DERIVE: computed/enriched columns
--
-- SKU NORMALIZATION (same canonical format as inventory):
-- UPPER → replace underscores with hyphens → TRIM.
-- Ensures transactions resolve to the correct product master
-- even when SKU formatting differs between source records.
--
-- STOCK MOVEMENT DIRECTION:
-- quantity < 0 = stock OUT (e.g. DISPATCH)
-- quantity > 0 = stock IN (e.g. RECEIPT, ADJUSTMENT_IN)
-- quantity = 0 = neutral (rare edge case, kept for completeness)
-- ============================================================
derived AS (

    SELECT
        *,

        -- SKU normalization (must match silver_linnworks_inventory)
        UPPER(
            REPLACE(TRIM(COALESCE(sku_raw, '')), '_', '-')
        )                                                           AS normalised_sku,

        -- Derived: stock movement direction
        CASE
            WHEN quantity < 0 THEN 'OUT'
            WHEN quantity > 0 THEN 'IN'
            ELSE 'NEUTRAL'
        END                                                         AS stock_movement_direction,

        -- Derived: absolute quantity for aggregation convenience
        ABS(quantity)                                               AS quantity_absolute

    FROM cleaned

),

-- ============================================================
-- SECTION 5: JOIN: resolve surviving stock_item_source_id
-- via silver_linnworks_inventory on normalised_sku.
-- This corrects fkStockItemId references that pointed to
-- duplicate (non-surviving) inventory records.
-- LEFT JOIN preserves transactions whose SKU cannot be
-- resolved (edge case: system_note explains these).
-- Filter: only join to surviving inventory records to avoid
-- resolving to a duplicate product master.
-- ============================================================
with_inventory AS (

    SELECT
        d.*,
        i.stock_item_source_id                                      AS resolved_stock_item_id,
        i.inv_sk                                                    AS resolved_inv_sk,
        i.item_title                                                AS resolved_item_title,
        i.category_name                                             AS resolved_category_name,
        i.swiftroute_client_id                                      AS resolved_client_id
    FROM derived d
    LEFT JOIN {{ ref('silver_linnworks_inventory') }} i
        ON d.normalised_sku = i.normalised_sku
        AND i.is_surviving_record = TRUE

),

-- ============================================================
-- SECTION 6: SURROGATE KEY + SILVER METADATA
-- txn_sk: human-readable surrogate (txn_00001, txn_00002 ...)
-- record_hash_key: MD5 of full row for incremental upserts
-- ============================================================
final AS (

    SELECT
        -- -------------------------------------------------------
        -- surrogate key
        -- -------------------------------------------------------
        'txn_' || LPAD(
            ROW_NUMBER() OVER (
                ORDER BY transaction_date ASC, transaction_source_id ASC
            )::TEXT, 6, '0'
        )                                                           AS txn_sk,

        -- -------------------------------------------------------
        -- natural key
        -- -------------------------------------------------------
        transaction_source_id,

        -- -------------------------------------------------------
        -- dbt incremental unique key
        -- -------------------------------------------------------
        MD5(
            COALESCE(transaction_source_id, '')     ||
            COALESCE(normalised_sku, '')            ||
            COALESCE(quantity::TEXT, '')            ||
            COALESCE(transaction_type, '')          ||
            COALESCE(transaction_date::TEXT, '')
        )                                                           AS record_hash_key,

        -- -------------------------------------------------------
        -- product reference (resolved to surviving record)
        -- -------------------------------------------------------
        resolved_stock_item_id,
        resolved_inv_sk,
        normalised_sku,
        sku_raw,
        item_title,
        resolved_item_title,
        resolved_category_name,
        resolved_client_id,

        -- -------------------------------------------------------
        -- transaction details
        -- -------------------------------------------------------
        transaction_type,
        transaction_note,
        stock_movement_direction,
        quantity,
        quantity_absolute,
        stock_value,

        -- -------------------------------------------------------
        -- order linkage
        -- -------------------------------------------------------
        order_reference_number,

        -- -------------------------------------------------------
        -- warehouse
        -- -------------------------------------------------------
        location,
        bin_rack,

        -- -------------------------------------------------------
        -- timestamps
        -- -------------------------------------------------------
        transaction_date,

        -- -------------------------------------------------------
        -- system notes (known quirk documentation)
        -- -------------------------------------------------------
        system_note,

        -- -------------------------------------------------------
        -- silver metadata
        -- -------------------------------------------------------
        NOW()                                                       AS silver_loaded_at,
        'silver_linnworks_stock_transactions'                       AS silver_source_model

    FROM with_inventory

)

SELECT * FROM final