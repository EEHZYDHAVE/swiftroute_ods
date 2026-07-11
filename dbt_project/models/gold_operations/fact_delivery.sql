-- ============================================================
-- model:        fact_delivery
-- layer:        gold_operations (fact table)
-- description:  Central fact table for delivery operations.
--               One row per Onfleet delivery task. Combines
--               delivery events from Onfleet with driver
--               labour cost from Gusto, trip metrics from
--               Samsara, and contracted rates from Salesforce.
--
-- key facts:
--   - delivery_id: Onfleet task id (natural key, degenerate
--     dimension, kept for operational traceability).
--   - onfleet_task_id: same as delivery_id, explicit alias
--     for clarity when joining back to Onfleet.
--   - grain: one row per delivery task.
--   - driver_labour_cost: derived from Gusto bi_weekly_gross
--     divided by estimated deliveries per pay period.
--     Formula: bi_weekly_gross / avg_deliveries_per_period.
--     This is an approximation. Delivery count per driver
--     per period is calculated from silver_onfleet_deliveries.
--   - contracted_rate: the net rate from dim_contract_rate
--     matched on client, service_type, and zone.
--   - courier_fee: contracted_rate * 1 (per delivery unit).
--   - sla_met_flag: TRUE if completed_at <= complete_before.
--   - delivery_mode: derived from vehicle_type on the delivery
--     metadata field.
--   - All dimension keys resolved via LEFT JOIN to preserve
--     deliveries where a dimension cannot be resolved.
--
-- incremental:  Append/upsert on delivery_id. New deliveries
--               from future bronze loads are appended. Existing
--               deliveries update if their hash changes.
--
-- depends_on:   silver.silver_onfleet_deliveries
--               silver.silver_samsara_trips
--               silver.silver_gusto_payroll_compensations
--               driver_id_map
--               dim_client
--               dim_driver
--               dim_vehicle
--               dim_zone
--               dim_service_type
--               dim_contract_rate
--               dim_date
-- ============================================================

{{
    config(
        materialized='incremental',
        unique_key='delivery_id',
        on_schema_change='sync_all_columns',
        schema='gold_operations'
    )
}}

-- ============================================================
-- SECTION 1: BASE DELIVERIES FROM SILVER
-- ============================================================
WITH deliveries AS (

    SELECT
        delivery_source_id,
        del_sk,
        tracking_url,
        client_id                                                   AS swiftroute_client_id,
        zone_id,
        service_type,
        vehicle_type                                                AS delivery_vehicle_type,
        driver_id,
        organization_id,
        merchant_id,
        creator_id,
        creator_type,
        state_code,
        delivery_status,
        is_pickup_task,
        completion_success,
        completion_result,
        failure_reason,
        is_late_delivery,
        destination_city,
        destination_state,
        destination_lng,
        destination_lat,
        recipient_name,
        recipient_phone,
        order_value,
        service_time_minutes,
        delivery_duration_minutes,
        completion_distance_meters,
        notes,
        created_at,
        complete_after,
        complete_before,
        completed_at,
        last_modified_at,
        silver_loaded_at
    FROM {{ ref('silver_onfleet_deliveries') }}

    {% if is_incremental() %}
    WHERE silver_loaded_at > (
        SELECT MAX(created_ts) FROM {{ this }}
    )
    {% endif %}

),

-- ============================================================
-- SECTION 2: DRIVER LABOUR COST CALCULATION
-- Approximate driver labour cost per delivery using Gusto
-- bi_weekly_gross and delivery count per pay period.
-- Steps:
-- 1. Count completed deliveries per driver per pay period
--    from silver_onfleet_deliveries.
-- 2. Join to silver_gusto_payroll_compensations on emp_sk
--    via driver_id_map to get bi_weekly_gross.
-- 3. Divide bi_weekly_gross by delivery count for that period.
-- This gives cost per delivery for each driver per period.
-- Pipeline-safe: no hardcoded periods or rates.
-- ============================================================
driver_delivery_counts AS (

    SELECT
        d.driver_id,
        DATE_TRUNC('month', d.completed_at)                         AS delivery_month,
        COUNT(*)                                                    AS delivery_count
    FROM {{ ref('silver_onfleet_deliveries') }} d
    WHERE d.completed_at IS NOT NULL
    AND d.state_code = 3
    GROUP BY d.driver_id, DATE_TRUNC('month', d.completed_at)

),

payroll_by_driver AS (

    SELECT
        m.onfleet_worker_id                                         AS driver_id,
        DATE_TRUNC('month', p.check_date)                           AS pay_month,
        p.gross_pay                                                 AS bi_weekly_gross
    FROM {{ ref('silver_gusto_payroll_compensations') }} p
    JOIN {{ ref('driver_id_map') }} m
        ON p.employee_source_id = m.gusto_uuid

),

labour_cost_per_delivery AS (

    SELECT
        dc.driver_id,
        dc.delivery_month,
        dc.delivery_count,
        pb.bi_weekly_gross,
        CASE
            WHEN dc.delivery_count > 0
            THEN ROUND(pb.bi_weekly_gross / dc.delivery_count, 4)
            ELSE NULL
        END                                                         AS labour_cost_per_delivery
    FROM driver_delivery_counts dc
    LEFT JOIN payroll_by_driver pb
        ON dc.driver_id = pb.driver_id
        AND dc.delivery_month = pb.pay_month

),

-- ============================================================
-- SECTION 3: RESOLVE SAMSARA TRIP FOR EACH DELIVERY
-- Match trips to deliveries by driver_id and date proximity.
-- A trip is matched if it started within 2 hours before
-- the delivery was created and ended before completion.
-- Pipeline-safe: time window tolerance handles minor timing
-- differences between systems.
-- ============================================================
trips AS (

    SELECT
        driver_id,
        vehicle_id,
        started_at,
        ended_at,
        distance_km,
        fuel_consumed_gallons,
        duration_minutes,
        safety_event_count
    FROM {{ ref('silver_samsara_trips') }}

),

-- ============================================================
-- SECTION 4: RESOLVE CONTRACTED RATE
-- Match contract rate on client, service_type, and zone.
-- Use the most recently effective rate where multiple rates
-- exist for the same combination.
-- Pipeline-safe: ROW_NUMBER ensures one rate per delivery.
-- ============================================================
rates_ranked AS (

    SELECT
        client_key,
        service_type,
        zone_id,
        contract_rate_key,
        net_rate,
        effective_date,
        ROW_NUMBER() OVER (
            PARTITION BY client_key, service_type, zone_id
            ORDER BY effective_date DESC
        )                                                           AS rate_rank
    FROM {{ ref('dim_contract_rate') }}

),

active_rates AS (

    SELECT
        client_key,
        service_type,
        zone_id,
        contract_rate_key,
        net_rate
    FROM rates_ranked
    WHERE rate_rank = 1

),

-- ============================================================
-- SECTION 5: RESOLVE VEHICLE FROM SAMSARA TRIPS
-- Match vehicle to delivery via driver and date.
-- LEFT JOIN to trips using driver_id and time window.
-- ============================================================
delivery_with_trip AS (

    SELECT
        d.*,
        t.vehicle_id                                                AS samsara_vehicle_id,
        t.distance_km                                               AS trip_distance_km,
        t.fuel_consumed_gallons                                     AS trip_fuel_gallons,
        t.duration_minutes                                          AS trip_duration_minutes,
        t.safety_event_count                                        AS trip_safety_events
    FROM deliveries d
    LEFT JOIN trips t
        ON d.driver_id = t.driver_id
        AND t.started_at BETWEEN (d.created_at - INTERVAL '2 hours') AND d.created_at
        AND t.ended_at <= COALESCE(d.completed_at, d.complete_before)

),

-- ============================================================
-- SECTION 6: JOIN ALL DIMENSIONS
-- ============================================================
with_dimensions AS (

    SELECT
        d.*,

        -- dim_client
        c.client_key,
        c.client_name,
        c.account_tier,

        -- dim_driver
        dr.driver_key,
        dr.driver_name,
        dr.driver_type,
        dr.bi_weekly_gross,

        -- dim_vehicle
        v.vehicle_key,
        v.vehicle_name,
        v.vehicle_type,
        v.vehicle_category,

        -- dim_zone
        z.zone_key,
        z.zone_name,
        z.city                                                      AS zone_city,
        z.region                                                    AS zone_region,

        -- dim_service_type
        st.service_type_key,
        st.service_type_name,
        st.sla_hours,

        -- dim_contract_rate
        r.contract_rate_key,
        r.net_rate                                                  AS contracted_rate,

        -- dim_date
        dd.date_key

    FROM delivery_with_trip d

    LEFT JOIN {{ ref('dim_client') }} c
        ON d.swiftroute_client_id = c.client_key

    LEFT JOIN {{ ref('dim_driver') }} dr
        ON d.driver_id = dr.driver_key

    LEFT JOIN {{ ref('dim_vehicle') }} v
        ON d.samsara_vehicle_id = v.vehicle_key

    LEFT JOIN {{ ref('dim_zone') }} z
        ON d.zone_id = z.zone_key

    LEFT JOIN {{ ref('dim_service_type') }} st
        ON d.service_type = st.service_type_key

    LEFT JOIN active_rates r
        ON d.swiftroute_client_id = r.client_key
        AND d.service_type = r.service_type
        AND d.zone_id = r.zone_id

    LEFT JOIN {{ ref('dim_date') }} dd
        ON d.created_at::DATE = dd.full_date

),

-- ============================================================
-- SECTION 7: JOIN LABOUR COST
-- ============================================================
with_labour AS (

    SELECT
        d.*,
        lc.labour_cost_per_delivery                                 AS driver_labour_cost
    FROM with_dimensions d
    LEFT JOIN labour_cost_per_delivery lc
        ON d.driver_id = lc.driver_id
        AND DATE_TRUNC('month', d.created_at) = lc.delivery_month

),

-- ============================================================
-- SECTION 8: DERIVE FINAL MEASURES
-- ============================================================
final AS (

    SELECT
        -- -------------------------------------------------------
        -- degenerate dimension keys (operational traceability)
        -- -------------------------------------------------------
        delivery_source_id                                          AS delivery_id,
        del_sk                                                      AS onfleet_task_id,

        -- -------------------------------------------------------
        -- dimension keys (FKs to star schema)
        -- -------------------------------------------------------
        client_key,
        driver_key,
        vehicle_key,
        zone_key,
        service_type_key,
        contract_rate_key,
        date_key,

        -- -------------------------------------------------------
        -- degenerate identifiers (no separate dimension table)
        -- -------------------------------------------------------
        swiftroute_client_id,
        zone_id,
        tracking_url,
        recipient_name,
        recipient_phone,

        -- -------------------------------------------------------
        -- delivery mode (derived from vehicle_type metadata)
        -- -------------------------------------------------------
        CASE
            WHEN delivery_vehicle_type ILIKE '%motor%'  THEN 'Motorcycle'
            WHEN delivery_vehicle_type ILIKE '%van%'    THEN 'Van'
            WHEN delivery_vehicle_type ILIKE '%car%'    THEN 'Car'
            ELSE INITCAP(COALESCE(delivery_vehicle_type, 'Unknown'))
        END                                                         AS delivery_mode,

        -- -------------------------------------------------------
        -- operational measures
        -- -------------------------------------------------------
        service_time_minutes                                        AS picked_time,
        NULL::NUMERIC                                               AS packed_time,
        delivery_duration_minutes                                   AS dispatched_time,
        delivery_duration_minutes                                   AS completion_time,
        ROUND(
            COALESCE(delivery_duration_minutes, 0) / 60.0
        , 2)                                                        AS actual_delivery_hours,
        ROUND(
            COALESCE(trip_duration_minutes, 0) / 60.0
        , 2)                                                        AS driver_time_hours,

        -- -------------------------------------------------------
        -- financial measures
        -- -------------------------------------------------------
        COALESCE(contracted_rate, 0)                                AS contracted_rate,
        COALESCE(driver_labour_cost, 0)                             AS driver_labour_cost,
        COALESCE(contracted_rate, 0)                                AS courier_fee,
        order_value                                                 AS cod_amount,

        -- -------------------------------------------------------
        -- performance measures
        -- -------------------------------------------------------
        CASE
            WHEN completed_at IS NOT NULL
            AND complete_before IS NOT NULL
            AND completed_at <= complete_before
            THEN TRUE
            WHEN completed_at IS NOT NULL
            AND complete_before IS NOT NULL
            AND completed_at > complete_before
            THEN FALSE
            ELSE NULL
        END                                                         AS sla_met_flag,

        delivery_status                                             AS payment_status,
        is_late_delivery,
        completion_success,
        failure_reason,

        -- -------------------------------------------------------
        -- trip metrics from Samsara
        -- -------------------------------------------------------
        trip_distance_km,
        trip_fuel_gallons,
        trip_safety_events,

        -- -------------------------------------------------------
        -- destination
        -- -------------------------------------------------------
        destination_city,
        destination_state,
        destination_lng,
        destination_lat,

        -- -------------------------------------------------------
        -- timestamps
        -- -------------------------------------------------------
        created_at,
        complete_after,
        complete_before,
        completed_at,

        -- -------------------------------------------------------
        -- audit
        -- -------------------------------------------------------
        NOW()                                                       AS created_ts

    FROM with_labour

)

SELECT * FROM final