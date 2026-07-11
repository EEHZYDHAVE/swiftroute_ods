-- ============================================================
-- model:        fact_inventory_transaction
-- layer:        gold_operations (fact table)
-- description:  Inventory movement fact table from Linnworks
--               stock transactions. One row per stock movement
--               event (dispatch, receipt, adjustment, etc).
--
-- key facts:
--   - inventory_txn_id: pkStockTransactionId (degenerate
--     dimension, kept for operational traceability).
--   - grain: one row per stock transaction event.
--   - sku_key: normalised_sku joins to dim_sku. Resolved
--     via silver_linnworks_stock_transactions which already
--     maps transactions to surviving inventory records.
--   - client_key: resolved from dim_sku via client_owner
--     since stock transactions do not carry client_id directly.
--   - zone_key: Linnworks transactions do not carry zone_id.
--     Zone is approximated from the fulfilment location
--     mapped to a city, then to the first zone in that city.
--     This is a known approximation, documented here.
--   - order_id: degenerate dimension. The Linnworks reference
--     number linking this transaction to an order.
--   - transaction_type: DISPATCH, RECEIPT, ADJUSTMENT etc.
--   - quantity: negative = stock out, positive = stock in.
--   - supplier: vendor or source of stock for receipts.
--     NULL for dispatch transactions.
--
-- incremental:  Append/upsert on inventory_txn_id.
--
-- depends_on:   silver.silver_linnworks_stock_transactions
--               dim_sku
--               dim_client
--               dim_zone
--               dim_date
-- ============================================================

{{
    config(
        materialized='incremental',
        unique_key='inventory_txn_id',
        on_schema_change='sync_all_columns',
        schema='gold_operations'
    )
}}

-- ============================================================
-- SECTION 1: BASE TRANSACTIONS FROM SILVER
-- ============================================================
WITH transactions AS (

    SELECT
        transaction_source_id,
        txn_sk,
        normalised_sku,
        resolved_stock_item_id,
        resolved_inv_sk,
        resolved_client_id,
        transaction_type,
        transaction_note,
        stock_movement_direction,
        quantity,
        quantity_absolute,
        stock_value,
        order_reference_number,
        location,
        bin_rack,
        transaction_date,
        system_note,
        silver_loaded_at
    FROM {{ ref('silver_linnworks_stock_transactions') }}

    {% if is_incremental() %}
    WHERE silver_loaded_at > (
        SELECT MAX(created_ts) FROM {{ this }}
    )
    {% endif %}

),

-- ============================================================
-- SECTION 2: RESOLVE ZONE FROM LOCATION
-- Linnworks location field holds warehouse name
-- (e.g. "Denver Warehouse"). Map to a representative zone
-- in that city as a best approximation since no zone_id
-- exists on stock transactions.
-- Pipeline-safe: ILIKE pattern matching, defaults to NULL
-- if location cannot be resolved to a known zone.
-- ============================================================
location_to_zone AS (

    SELECT DISTINCT
        zone_key,
        city
    FROM {{ ref('dim_zone') }}
    WHERE zone_number = '1'

),

-- ============================================================
-- SECTION 3: JOIN ALL DIMENSIONS
-- ============================================================
with_dimensions AS (

    SELECT
        t.*,

        -- dim_sku
        s.sku_key,
        s.sku_name,
        s.category_name,
        s.price,

        -- dim_client (via dim_sku.client_owner)
        s.client_owner                                              AS client_key,
        s.client_name,

        -- dim_zone (approximated from warehouse location)
        z.zone_key,

        -- dim_date
        dd.date_key

    FROM transactions t

    LEFT JOIN {{ ref('dim_sku') }} s
        ON t.normalised_sku = s.sku_key

    LEFT JOIN location_to_zone z
        ON t.location ILIKE '%' || z.city || '%'

    LEFT JOIN {{ ref('dim_date') }} dd
        ON t.transaction_date::DATE = dd.full_date

),

-- ============================================================
-- SECTION 4: FINAL SELECT
-- ============================================================
final AS (

    SELECT
        -- -------------------------------------------------------
        -- degenerate dimension (operational traceability)
        -- -------------------------------------------------------
        transaction_source_id                                       AS inventory_txn_id,
        txn_sk,

        -- -------------------------------------------------------
        -- dimension keys (FKs to star schema)
        -- -------------------------------------------------------
        sku_key,
        client_key,
        zone_key,
        date_key,

        -- -------------------------------------------------------
        -- degenerate identifiers
        -- -------------------------------------------------------
        order_reference_number                                      AS order_id,
        normalised_sku,
        location,
        bin_rack,

        -- -------------------------------------------------------
        -- transaction classification
        -- -------------------------------------------------------
        transaction_type,
        transaction_note,
        stock_movement_direction,

        -- -------------------------------------------------------
        -- measures
        -- -------------------------------------------------------
        quantity,
        quantity_absolute,
        stock_value,

        -- -------------------------------------------------------
        -- supplier (relevant for RECEIPT transactions)
        -- NULL for DISPATCH and ADJUSTMENT transactions
        -- -------------------------------------------------------
        CASE
            WHEN UPPER(transaction_type) = 'RECEIPT'
            THEN location
            ELSE NULL
        END                                                         AS supplier,

        -- -------------------------------------------------------
        -- timestamps
        -- -------------------------------------------------------
        transaction_date                                            AS transaction_timestamp,

        -- -------------------------------------------------------
        -- notes
        -- -------------------------------------------------------
        system_note                                                 AS note,

        -- -------------------------------------------------------
        -- audit
        -- -------------------------------------------------------
        NOW()                                                       AS created_ts

    FROM with_dimensions

)

SELECT * FROM final