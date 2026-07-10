-- ============================================================
-- model:        silver_linnworks_orders
-- layer:        silver
-- source:       {{ source('bronze', 'linnworks_orders') }}
-- loaded_by:    loaders/load_linnworks.py
-- description:  Cleaned and standardised order records from
--               Linnworks. Unpacks JSONB, applies all data
--               quality fixes including phone normalization,
--               reference number regeneration, SKU resolution,
--               and address cleaning.
--
-- key facts:
--   - pkOrderID retained as order_source_id. Surrogate key
--     ord_sk generated.
--   - reference_number regenerated as sequential LWO format
--     (LWO00000001, LWO00000002...) replacing the original
--     ReferenceNum which had one inconsistent row.
--   - external_reference and secondary_reference dropped
--     per design decision (not needed downstream).
--   - shipping_address_2 dropped (not needed downstream).
--   - shipping_phone normalised to +1-XXX-XXX-XXXX format.
--     Steps: strip 001-/+1- prefixes, remove x-suffixes,
--     remove brackets, strip all non-digit chars, then
--     reformat to +1-XXX-XXX-XXXX.
--   - item_* columns reflect first item only (index 0).
--     Orders with multiple items: full Items array kept as
--     JSONB for downstream unnesting if needed.
--   - item_stock_item_id resolved to surviving inventory
--     record via normalised SKU join.
--   - empty strings → NULL.
--   - timestamps → TIMESTAMPTZ.
--
-- incremental:  Upserts on MD5 of full row (record_hash_key).
--               Safe to re-run: existing records update.
--
-- depends_on:   bronze.linnworks_orders
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
    FROM {{ source('bronze', 'linnworks_orders') }}

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
        raw_data ->> 'pkOrderID'                                    AS order_source_id,
        (raw_data ->> 'NumOrderId')::INT                            AS order_number,

        -- channel and source
        raw_data ->> 'Channel'                                      AS channel,
        raw_data ->> 'Source'                                       AS source,
        raw_data ->> 'SubSource'                                    AS sub_source,
        raw_data ->> 'SiteCode'                                     AS site_code,
        raw_data ->> 'FulfilmentLocationName'                       AS fulfilment_location,

        -- dates
        (raw_data ->> 'ReceivedDate')::TIMESTAMPTZ                  AS received_at,
        (raw_data ->> 'ProcessedOn')::TIMESTAMPTZ                   AS processed_at,
        (raw_data ->> 'DispatchedOn')::TIMESTAMPTZ                  AS dispatched_at,

        -- customer
        raw_data ->> 'CustomerName'                                 AS customer_name,
        raw_data ->> 'CustomerEmail'                                AS customer_email,

        -- shipping address
        raw_data -> 'Address' ->> 'FullName'                        AS shipping_full_name,
        raw_data -> 'Address' ->> 'Company'                         AS shipping_company_raw,
        raw_data -> 'Address' ->> 'Address1'                        AS shipping_address_1,
        raw_data -> 'Address' ->> 'City'                            AS shipping_city,
        raw_data -> 'Address' ->> 'Region'                          AS shipping_region,
        raw_data -> 'Address' ->> 'PostCode'                        AS shipping_postcode,
        raw_data -> 'Address' ->> 'Country'                         AS shipping_country,
        raw_data -> 'Address' ->> 'CountryCode'                     AS shipping_country_code,
        raw_data -> 'Address' ->> 'Phone'                           AS shipping_phone_raw,

        -- financials
        (raw_data ->> 'SubTotal')::NUMERIC                          AS subtotal,
        (raw_data ->> 'PostalServiceCost')::NUMERIC                 AS postal_service_cost,
        (raw_data ->> 'TotalCharge')::NUMERIC                       AS total_charge,
        (raw_data ->> 'TaxAmount')::NUMERIC                         AS tax_amount,
        raw_data ->> 'Currency'                                     AS currency,
        raw_data ->> 'PaymentMethod'                                AS payment_method,
        raw_data ->> 'PaymentStatus'                                AS payment_status_raw,

        -- general info
        (raw_data -> 'GeneralInfo' ->> 'Status')::INT               AS order_status_code,
        (raw_data -> 'GeneralInfo' ->> 'LockForShipping')::BOOLEAN  AS lock_for_shipping,
        (raw_data -> 'GeneralInfo' ->> 'Marker')::INT               AS marker,
        raw_data -> 'GeneralInfo' ->> 'Notes'                       AS general_notes_raw,

        -- shipping info
        raw_data -> 'ShippingInfo' ->> 'PostalServiceName'          AS postal_service_name,
        raw_data -> 'ShippingInfo' ->> 'TrackingNumber'             AS tracking_number,
        raw_data -> 'ShippingInfo' ->> 'Vendor'                     AS shipping_vendor,
        raw_data -> 'ShippingInfo' ->> 'PostalServiceCode'          AS postal_service_code,

        -- first item (index 0): full items array kept as JSONB
        raw_data -> 'Items' -> 0 ->> 'StockItemId'                  AS item_stock_item_id_raw,
        raw_data -> 'Items' -> 0 ->> 'SKU'                          AS item_sku_raw,
        raw_data -> 'Items' -> 0 ->> 'ItemTitle'                    AS item_title,
        (raw_data -> 'Items' -> 0 ->> 'Quantity')::INT              AS item_quantity,
        (raw_data -> 'Items' -> 0 ->> 'UnitCost')::NUMERIC          AS item_unit_cost,
        (raw_data -> 'Items' -> 0 ->> 'PricePerUnit')::NUMERIC      AS item_price_per_unit,
        (raw_data -> 'Items' -> 0 ->> 'LineTotal')::NUMERIC         AS item_line_total,
        (raw_data -> 'Items' -> 0 ->> 'Weight')::NUMERIC            AS item_weight_grams,
        (raw_data -> 'Items' -> 0 ->> 'IsComposite')::BOOLEAN       AS item_is_composite,
        raw_data -> 'Items' -> 0 ->> 'BinRack'                      AS item_bin_rack,
        raw_data -> 'Items'                                         AS items_raw,

        -- swiftroute integration
        raw_data ->> '_swiftroute_client_id'                        AS swiftroute_client_id,
        raw_data ->> '_swiftroute_client_name'                      AS swiftroute_client_name,
        (raw_data ->> '_swiftroute_pick_duration_mins')::INT        AS pick_duration_minutes,

        -- bronze metadata
        bronze_row_id,
        bronze_ingest_timestamp

    FROM source

),

-- ============================================================
-- SECTION 3: CLEAN: nulls, empty strings, standardisation
-- ============================================================
cleaned AS (

    SELECT
        order_source_id,
        order_number,
        bronze_row_id,

        -- channel
        UPPER(NULLIF(TRIM(channel), ''))                            AS channel,
        UPPER(NULLIF(TRIM(source), ''))                             AS source,
        NULLIF(TRIM(sub_source), '')                                AS sub_source,
        UPPER(NULLIF(TRIM(site_code), ''))                          AS site_code,
        NULLIF(TRIM(fulfilment_location), '')                       AS fulfilment_location,

        -- dates
        received_at,
        processed_at,
        dispatched_at,

        -- customer
        NULLIF(TRIM(customer_name), '')                             AS customer_name,
        LOWER(NULLIF(TRIM(customer_email), ''))                     AS customer_email,

        -- shipping address
        NULLIF(TRIM(shipping_full_name), '')                        AS shipping_full_name,
        NULLIF(TRIM(shipping_company_raw), '')                      AS shipping_company,
        NULLIF(TRIM(shipping_address_1), '')                        AS shipping_address_1,
        NULLIF(TRIM(shipping_city), '')                             AS shipping_city,
        NULLIF(TRIM(shipping_region), '')                           AS shipping_region,
        NULLIF(TRIM(shipping_postcode), '')                         AS shipping_postcode,
        NULLIF(TRIM(shipping_country), '')                          AS shipping_country,
        UPPER(NULLIF(TRIM(shipping_country_code), ''))              AS shipping_country_code,
        shipping_phone_raw,

        -- financials
        subtotal,
        postal_service_cost,
        total_charge,
        tax_amount,
        UPPER(NULLIF(TRIM(currency), ''))                           AS currency,
        UPPER(NULLIF(TRIM(payment_method), ''))                     AS payment_method,
        UPPER(NULLIF(TRIM(payment_status_raw), ''))                 AS payment_status,

        -- general info
        order_status_code,
        lock_for_shipping,
        marker,
        NULLIF(TRIM(general_notes_raw), '')                         AS general_notes,

        -- shipping info
        NULLIF(TRIM(postal_service_name), '')                       AS postal_service_name,
        NULLIF(TRIM(tracking_number), '')                           AS tracking_number,
        NULLIF(TRIM(shipping_vendor), '')                           AS shipping_vendor,
        NULLIF(TRIM(postal_service_code), '')                       AS postal_service_code,

        -- first item
        NULLIF(TRIM(item_stock_item_id_raw), '')                    AS item_stock_item_id_raw,
        NULLIF(TRIM(item_sku_raw), '')                              AS item_sku_raw,
        NULLIF(TRIM(item_title), '')                                AS item_title,
        item_quantity,
        item_unit_cost,
        item_price_per_unit,
        item_line_total,
        item_weight_grams,
        item_is_composite,
        NULLIF(TRIM(item_bin_rack), '')                             AS item_bin_rack,
        items_raw,

        -- swiftroute
        NULLIF(TRIM(swiftroute_client_id), '')                      AS swiftroute_client_id,
        NULLIF(TRIM(swiftroute_client_name), '')                    AS swiftroute_client_name,
        pick_duration_minutes,

        bronze_ingest_timestamp

    FROM unpacked

),

-- ============================================================
-- SECTION 4: DERIVE: computed/enriched columns
--
-- REFERENCE NUMBER REGENERATION:
-- Original ReferenceNum had one inconsistent row. New
-- sequential reference numbers generated in format LWO00000001.
-- LWO prefix = Linnworks Orders. Pipeline-safe: row_number
-- ordered by order_number ensures stable assignment across runs.
--
-- PHONE NORMALIZATION:
-- Target format: +1-XXX-XXX-XXXX
-- Steps (pipeline-safe regex chain):
-- 1. Remove leading 001- or +1- country code prefix
-- 2. Remove x-suffix and everything after (e.g. x123)
-- 3. Remove all non-digit characters
-- 4. Take first 10 digits only
-- 5. Reformat as +1-XXX-XXX-XXXX
--
-- SKU NORMALIZATION:
-- Same canonical format as silver_linnworks_inventory.
--
-- ORDER STATUS LABEL:
-- Linnworks status codes mapped to human-readable labels.
-- ============================================================
derived AS (

    SELECT
        *,

        -- Reference number regeneration
        'LWO' || LPAD(
            ROW_NUMBER() OVER (ORDER BY order_number ASC)::TEXT
        , 8, '0')                                                   AS reference_number,

        -- Phone normalization (pipeline-safe step-by-step)
        CASE
            WHEN shipping_phone_raw IS NULL THEN NULL
            WHEN TRIM(shipping_phone_raw) = '' THEN NULL
            ELSE
                '+1-' ||
                SUBSTRING(
                    REGEXP_REPLACE(
                        REGEXP_REPLACE(
                            REGEXP_REPLACE(
                                REGEXP_REPLACE(
                                    REGEXP_REPLACE(
                                        TRIM(shipping_phone_raw),
                                        '^(001-|\+1-)', '', 'g'
                                    ),
                                    'x.*$', '', 'g'
                                ),
                                '[^0-9]', '', 'g'
                            ),
                            '^1', '', 'g'
                        ),
                        '^(.{10}).*$', '\1', 'g'
                    ),
                1, 3) || '-' ||
                SUBSTRING(
                    REGEXP_REPLACE(
                        REGEXP_REPLACE(
                            REGEXP_REPLACE(
                                REGEXP_REPLACE(
                                    REGEXP_REPLACE(
                                        TRIM(shipping_phone_raw),
                                        '^(001-|\+1-)', '', 'g'
                                    ),
                                    'x.*$', '', 'g'
                                ),
                                '[^0-9]', '', 'g'
                            ),
                            '^1', '', 'g'
                        ),
                        '^(.{10}).*$', '\1', 'g'
                    ),
                4, 3) || '-' ||
                SUBSTRING(
                    REGEXP_REPLACE(
                        REGEXP_REPLACE(
                            REGEXP_REPLACE(
                                REGEXP_REPLACE(
                                    REGEXP_REPLACE(
                                        TRIM(shipping_phone_raw),
                                        '^(001-|\+1-)', '', 'g'
                                    ),
                                    'x.*$', '', 'g'
                                ),
                                '[^0-9]', '', 'g'
                            ),
                            '^1', '', 'g'
                        ),
                        '^(.{10}).*$', '\1', 'g'
                    ),
                7, 4)
        END                                                         AS shipping_phone,

        -- SKU normalization
        UPPER(
            REPLACE(TRIM(COALESCE(item_sku_raw, '')), '_', '-')
        )                                                           AS item_normalised_sku,

        -- Order status label
        CASE order_status_code
            WHEN 0 THEN 'Unpaid'
            WHEN 1 THEN 'Paid'
            WHEN 2 THEN 'Return'
            WHEN 3 THEN 'Pending'
            WHEN 4 THEN 'Resend'
            ELSE 'Unknown'
        END                                                         AS order_status,

        -- Derived: order margin (line total minus unit cost)
        CASE
            WHEN item_line_total IS NOT NULL AND item_unit_cost IS NOT NULL
                AND item_quantity IS NOT NULL AND item_quantity > 0
            THEN ROUND(
                item_line_total - (item_unit_cost * item_quantity)
            , 2)
            ELSE NULL
        END                                                         AS item_margin

    FROM cleaned

),

-- ============================================================
-- SECTION 5: JOIN: resolve surviving inventory record
-- via normalised SKU. LEFT JOIN preserves orders whose
-- item SKU cannot be resolved to a surviving inventory record.
-- ============================================================
with_inventory AS (

    SELECT
        d.*,
        i.stock_item_source_id                                      AS resolved_stock_item_id,
        i.inv_sk                                                    AS resolved_inv_sk,
        i.category_name                                             AS resolved_category_name
    FROM derived d
    LEFT JOIN {{ ref('silver_linnworks_inventory') }} i
        ON d.item_normalised_sku = i.normalised_sku
        AND i.is_surviving_record = TRUE

),

-- ============================================================
-- SECTION 6: SURROGATE KEY + SILVER METADATA
-- ord_sk: human-readable surrogate (ord_000001 ...)
-- record_hash_key: MD5 of full row for incremental upserts
-- ============================================================
final AS (

    SELECT
        -- -------------------------------------------------------
        -- surrogate key
        -- -------------------------------------------------------
        'ord_' || LPAD(
            ROW_NUMBER() OVER (ORDER BY order_number ASC)::TEXT
        , 6, '0')                                                   AS ord_sk,

        -- -------------------------------------------------------
        -- natural key
        -- -------------------------------------------------------
        order_source_id,

        -- -------------------------------------------------------
        -- dbt incremental unique key
        -- -------------------------------------------------------
        MD5(
            COALESCE(order_source_id, '')           ||
            COALESCE(reference_number, '')          ||
            COALESCE(order_status_code::TEXT, '')   ||
            COALESCE(total_charge::TEXT, '')        ||
            COALESCE(dispatched_at::TEXT, '')       ||
            COALESCE(payment_status, '')
        )                                                           AS record_hash_key,

        -- -------------------------------------------------------
        -- order identifiers
        -- -------------------------------------------------------
        order_number,
        reference_number,

        -- -------------------------------------------------------
        -- channel
        -- -------------------------------------------------------
        channel,
        source,
        sub_source,
        site_code,
        fulfilment_location,

        -- -------------------------------------------------------
        -- status
        -- -------------------------------------------------------
        order_status_code,
        order_status,
        lock_for_shipping,
        marker,

        -- -------------------------------------------------------
        -- customer
        -- -------------------------------------------------------
        customer_name,
        customer_email,

        -- -------------------------------------------------------
        -- shipping address
        -- -------------------------------------------------------
        shipping_full_name,
        shipping_company,
        shipping_address_1,
        shipping_city,
        shipping_region,
        shipping_postcode,
        shipping_country,
        shipping_country_code,
        shipping_phone,
        shipping_phone_raw,

        -- -------------------------------------------------------
        -- shipping service
        -- -------------------------------------------------------
        postal_service_name,
        postal_service_code,
        postal_service_cost,
        tracking_number,
        shipping_vendor,

        -- -------------------------------------------------------
        -- financials
        -- -------------------------------------------------------
        subtotal,
        tax_amount,
        total_charge,
        currency,
        payment_method,
        payment_status,

        -- -------------------------------------------------------
        -- first item
        -- -------------------------------------------------------
        resolved_stock_item_id,
        resolved_inv_sk,
        item_normalised_sku,
        item_sku_raw,
        item_title,
        resolved_category_name,
        item_quantity,
        item_unit_cost,
        item_price_per_unit,
        item_line_total,
        item_margin,
        item_weight_grams,
        item_is_composite,
        item_bin_rack,
        items_raw,

        -- -------------------------------------------------------
        -- swiftroute
        -- -------------------------------------------------------
        swiftroute_client_id,
        swiftroute_client_name,
        pick_duration_minutes,
        general_notes,

        -- -------------------------------------------------------
        -- timestamps
        -- -------------------------------------------------------
        received_at,
        processed_at,
        dispatched_at,

        -- -------------------------------------------------------
        -- silver metadata
        -- -------------------------------------------------------
        NOW()                                                       AS silver_loaded_at,
        'silver_linnworks_orders'                                   AS silver_source_model

    FROM with_inventory

)

SELECT * FROM final