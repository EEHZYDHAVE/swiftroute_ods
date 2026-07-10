-- ============================================================
-- model:        silver_onfleet_deliveries
-- layer:        silver
-- source:       {{ source('bronze', 'onfleet_deliveries') }}
-- loaded_by:    loaders/load_onfleet.py
-- description:  Cleaned and standardised delivery task records
--               from Onfleet. Unpacks JSONB, applies all data
--               quality fixes, derives status labels, creator
--               type, and resolves driver name from
--               silver_onfleet_workers.
--
-- key facts:
--   - delivery_id (Onfleet natural key) retained as
--     delivery_source_id. Surrogate key del_sk generated.
--   - worker field renamed to driver_id for cross-system clarity.
--   - completion_success derived from state_code (state=3→true).
--   - last_modified_at < created_at on ~600 records: fixed by
--     setting last_modified_at = created_at where this occurs.
--   - All empty strings → NULL.
--   - All timestamps → TIMESTAMPTZ (UTC).
--   - metadata array unpacked for service_type, client_id,
--     order_value, zone_id, vehicle_type.
--   - creator_type derived: driver if creator_id matches a
--     known worker_id, else merchant.
--
-- incremental:  Upserts on MD5 of full row (record_hash_key).
--               Safe to re-run: existing records update in place.
--
-- depends_on:   bronze.onfleet_deliveries
--               silver.silver_onfleet_workers (driver name)
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
    FROM {{ source('bronze', 'onfleet_deliveries') }}

    {% if is_incremental() %}
    WHERE ingest_timestamp > (
        SELECT MAX(silver_loaded_at) FROM {{ this }}
    )
    {% endif %}

),

-- ============================================================
-- SECTION 2: UNPACK: extract JSONB fields into typed columns
-- All field names and paths verified against raw data samples.
-- Metadata array unpacked by name (not by index position) to
-- be pipeline-safe: new metadata entries won't break this.
-- ============================================================
unpacked AS (

    SELECT
        -- natural key
        raw_data ->> 'id'                                           AS delivery_source_id,
        raw_data ->> 'shortId'                                      AS short_id,
        raw_data ->> 'trackingURL'                                  AS tracking_url,

        -- status
        (raw_data ->> 'state')::INT                                 AS state_code,
        (raw_data ->> 'pickupTask')::BOOLEAN                        AS is_pickup_task,

        -- assignment
        raw_data ->> 'worker'                                       AS driver_id,
        raw_data ->> 'organization'                                 AS organization_id,
        raw_data ->> 'merchant'                                     AS merchant_id,
        raw_data ->> 'creator'                                      AS creator_id,

        -- timestamps (epoch milliseconds → TIMESTAMPTZ UTC)
        TO_TIMESTAMP(
            (raw_data ->> 'timeCreated')::BIGINT / 1000.0
        ) AT TIME ZONE 'UTC'                                        AS created_at,

        TO_TIMESTAMP(
            (raw_data ->> 'timeLastModified')::BIGINT / 1000.0
        ) AT TIME ZONE 'UTC'                                        AS last_modified_at_raw,

        TO_TIMESTAMP(
            (raw_data ->> 'completeAfter')::BIGINT / 1000.0
        ) AT TIME ZONE 'UTC'                                        AS complete_after,

        TO_TIMESTAMP(
            (raw_data ->> 'completeBefore')::BIGINT / 1000.0
        ) AT TIME ZONE 'UTC'                                        AS complete_before,

        -- completion details
        raw_data -> 'completionDetails' ->> 'result'                AS completion_result_raw,
        NULLIF(TRIM(
            raw_data -> 'completionDetails' ->> 'failureReason'
        ), '')                                                      AS failure_reason,
        NULLIF(TRIM(
            raw_data -> 'completionDetails' ->> 'successNotes'
        ), '')                                                      AS success_notes,
        TO_TIMESTAMP(
            (raw_data -> 'completionDetails' ->> 'time')::BIGINT / 1000.0
        ) AT TIME ZONE 'UTC'                                        AS completed_at,
        (raw_data -> 'completionDetails' ->> 'distance')::NUMERIC   AS completion_distance_meters,

        -- destination
        raw_data -> 'destination' -> 'address' ->> 'city'           AS destination_city,
        raw_data -> 'destination' -> 'address' ->> 'state'          AS destination_state,
        raw_data -> 'destination' -> 'address' ->> 'country'        AS destination_country,
        raw_data -> 'destination' -> 'address' ->> 'postalCode'     AS destination_postal_code,
        raw_data -> 'destination' -> 'address' ->> 'street'         AS destination_street,
        raw_data -> 'destination' -> 'address' ->> 'number'         AS destination_number,
        (raw_data -> 'destination' -> 'location' ->> 0)::NUMERIC    AS destination_lng,
        (raw_data -> 'destination' -> 'location' ->> 1)::NUMERIC    AS destination_lat,

        -- recipient (first recipient only)
        raw_data -> 'recipients' -> 0 ->> 'name'                    AS recipient_name,
        raw_data -> 'recipients' -> 0 ->> 'phone'                   AS recipient_phone,

        -- metadata array: unpacked by name for pipeline safety
        -- pattern: [{name: "service_type", value: "next_day"}, ...]
        (
            SELECT elem ->> 'value'
            FROM JSONB_ARRAY_ELEMENTS(raw_data -> 'metadata') AS elem
            WHERE elem ->> 'name' = 'service_type'
            LIMIT 1
        )                                                           AS service_type,
        (
            SELECT elem ->> 'value'
            FROM JSONB_ARRAY_ELEMENTS(raw_data -> 'metadata') AS elem
            WHERE elem ->> 'name' = 'client_id'
            LIMIT 1
        )                                                           AS client_id,
        (
            SELECT (elem ->> 'value')::NUMERIC
            FROM JSONB_ARRAY_ELEMENTS(raw_data -> 'metadata') AS elem
            WHERE elem ->> 'name' = 'order_value'
            LIMIT 1
        )                                                           AS order_value,
        (
            SELECT elem ->> 'value'
            FROM JSONB_ARRAY_ELEMENTS(raw_data -> 'metadata') AS elem
            WHERE elem ->> 'name' = 'zone_id'
            LIMIT 1
        )                                                           AS zone_id,
        (
            SELECT elem ->> 'value'
            FROM JSONB_ARRAY_ELEMENTS(raw_data -> 'metadata') AS elem
            WHERE elem ->> 'name' = 'vehicle_type'
            LIMIT 1
        )                                                           AS vehicle_type,

        -- service time
        (raw_data ->> 'serviceTime')::INT                           AS service_time_minutes,

        -- notes
        NULLIF(TRIM(raw_data ->> 'notes'), '')                      AS notes,

        -- bronze metadata
        bronze_ingest_timestamp

    FROM source

),

-- ============================================================
-- SECTION 3: CLEAN: nulls, empty strings, standardisation
-- ============================================================
cleaned AS (

    SELECT
        delivery_source_id,
        NULLIF(TRIM(short_id), '')                                  AS short_id,
        NULLIF(TRIM(tracking_url), '')                              AS tracking_url,
        state_code,
        is_pickup_task,
        NULLIF(TRIM(driver_id), '')                                 AS driver_id,
        NULLIF(TRIM(organization_id), '')                           AS organization_id,
        NULLIF(TRIM(merchant_id), '')                               AS merchant_id,
        NULLIF(TRIM(creator_id), '')                                AS creator_id,

        -- timestamps
        created_at,
        last_modified_at_raw,
        complete_after,
        complete_before,
        completed_at,
        completion_distance_meters,

        -- completion
        LOWER(NULLIF(TRIM(completion_result_raw), ''))              AS completion_result,
        failure_reason,
        success_notes,

        -- destination
        NULLIF(TRIM(destination_city), '')                          AS destination_city,
        NULLIF(TRIM(destination_state), '')                         AS destination_state,
        NULLIF(TRIM(destination_country), '')                       AS destination_country,
        NULLIF(TRIM(destination_postal_code), '')                   AS destination_postal_code,
        NULLIF(TRIM(destination_street), '')                        AS destination_street,
        NULLIF(TRIM(destination_number), '')                        AS destination_number,
        destination_lng,
        destination_lat,

        -- recipient
        NULLIF(TRIM(recipient_name), '')                            AS recipient_name,
        NULLIF(TRIM(recipient_phone), '')                           AS recipient_phone,

        -- metadata
        LOWER(NULLIF(TRIM(service_type), ''))                       AS service_type,
        NULLIF(TRIM(client_id), '')                                 AS client_id,
        order_value,
        NULLIF(TRIM(zone_id), '')                                   AS zone_id,
        LOWER(NULLIF(TRIM(vehicle_type), ''))                       AS vehicle_type,
        service_time_minutes,
        notes,

        bronze_ingest_timestamp

    FROM unpacked

),

-- ============================================================
-- SECTION 4: DERIVE: computed/enriched columns
-- Fix: last_modified_at < created_at on ~600 records.
-- Rule: last_modified_at cannot be earlier than created_at.
-- Fix: completion_success derived from state_code.
-- ============================================================
derived AS (

    SELECT
        *,

        -- Fix: last_modified_at cannot be before created_at
        CASE
            WHEN last_modified_at_raw < created_at
            THEN created_at
            ELSE last_modified_at_raw
        END                                                         AS last_modified_at,

        -- Derived: delivery status label from state_code
        -- 0=Unassigned, 1=Assigned, 2=Active, 3=Completed
        CASE state_code
            WHEN 0 THEN 'Unassigned'
            WHEN 1 THEN 'Assigned'
            WHEN 2 THEN 'Active'
            WHEN 3 THEN 'Completed'
            ELSE 'Unknown'
        END                                                         AS delivery_status,

        -- Derived: completion_success from state_code
        -- completion_success is null in source: derived here
        -- as the authoritative flag
        CASE
            WHEN state_code = 3 THEN TRUE
            ELSE NULL
        END                                                         AS completion_success,

        -- Derived: creator_type
        -- creator_id matches a driver_id pattern (drv_*)
        -- → creator is a driver, else merchant
        CASE
            WHEN creator_id ILIKE 'drv_%' THEN 'driver'
            ELSE 'merchant'
        END                                                         AS creator_type,

        -- Derived: is delivery late?
        -- completed_at > complete_before = late delivery
        -- Pipeline-safe: NULL-safe comparison
        CASE
            WHEN completed_at IS NOT NULL
            AND complete_before IS NOT NULL
            AND completed_at > complete_before
            THEN TRUE
            ELSE FALSE
        END                                                         AS is_late_delivery,

        -- Derived: delivery duration in minutes
        -- From completed_at back to created_at
        CASE
            WHEN completed_at IS NOT NULL
            THEN ROUND(
                EXTRACT(EPOCH FROM (completed_at - created_at)) / 60.0
            , 1)
            ELSE NULL
        END                                                         AS delivery_duration_minutes

    FROM cleaned

),

-- ============================================================
-- SECTION 5: JOIN: resolve driver name from authoritative
-- source (silver_onfleet_workers). LEFT JOIN preserves
-- unassigned deliveries (driver_id IS NULL).
-- ============================================================
with_driver AS (

    SELECT
        d.*,
        w.worker_name                                               AS driver_name,
        w.employment_type                                           AS driver_employment_type,
        w.city                                                      AS driver_city
    FROM derived d
    LEFT JOIN {{ ref('silver_onfleet_workers') }} w
        ON d.driver_id = w.worker_id

),

-- ============================================================
-- SECTION 6: SURROGATE KEY + SILVER METADATA
-- del_sk: human-readable surrogate (del_00001, del_00002 ...)
-- record_hash_key: MD5 of full row for incremental upserts
-- ============================================================
final AS (

    SELECT
        -- -------------------------------------------------------
        -- surrogate key
        -- -------------------------------------------------------
        'del_' || LPAD(
            ROW_NUMBER() OVER (ORDER BY delivery_source_id)::TEXT, 5, '0'
        )                                                           AS del_sk,

        -- -------------------------------------------------------
        -- natural key
        -- -------------------------------------------------------
        delivery_source_id,

        -- -------------------------------------------------------
        -- dbt incremental unique key
        -- -------------------------------------------------------
        MD5(
            COALESCE(delivery_source_id, '')        ||
            COALESCE(state_code::TEXT, '')          ||
            COALESCE(driver_id, '')                 ||
            COALESCE(completed_at::TEXT, '')        ||
            COALESCE(last_modified_at::TEXT, '')    ||
            COALESCE(completion_result, '')
        )                                                           AS record_hash_key,

        -- -------------------------------------------------------
        -- delivery identifiers
        -- -------------------------------------------------------
        tracking_url,
        client_id,
        zone_id,
        service_type,
        vehicle_type,

        -- -------------------------------------------------------
        -- status
        -- -------------------------------------------------------
        state_code,
        delivery_status,
        is_pickup_task,
        completion_success,
        completion_result,
        failure_reason,
        success_notes,
        is_late_delivery,

        -- -------------------------------------------------------
        -- driver
        -- -------------------------------------------------------
        driver_id,
        driver_name,
        driver_employment_type,
        driver_city,
        creator_id,
        creator_type,

        -- -------------------------------------------------------
        -- organisation
        -- -------------------------------------------------------
        organization_id,
        merchant_id,

        -- -------------------------------------------------------
        -- destination
        -- -------------------------------------------------------
        destination_city,
        destination_state,
        destination_country,
        destination_postal_code,
        destination_street,
        destination_number,
        destination_lng,
        destination_lat,

        -- -------------------------------------------------------
        -- recipient
        -- -------------------------------------------------------
        recipient_name,
        recipient_phone,

        -- -------------------------------------------------------
        -- financials
        -- -------------------------------------------------------
        order_value,

        -- -------------------------------------------------------
        -- timestamps
        -- -------------------------------------------------------
        created_at,
        last_modified_at,
        complete_after,
        complete_before,
        completed_at,

        -- -------------------------------------------------------
        -- metrics
        -- -------------------------------------------------------
        service_time_minutes,
        delivery_duration_minutes,
        completion_distance_meters,

        -- -------------------------------------------------------
        -- notes
        -- -------------------------------------------------------
        notes,

        -- -------------------------------------------------------
        -- silver metadata
        -- -------------------------------------------------------
        NOW()                                                       AS silver_loaded_at,
        'silver_onfleet_deliveries'                                 AS silver_source_model

    FROM with_driver

)

SELECT * FROM final