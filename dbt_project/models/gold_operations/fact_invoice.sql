-- ============================================================
-- model:        fact_invoice
-- layer:        gold_operations (fact table)
-- description:  Billing fact table combining QuickBooks
--               invoices and payments with Salesforce contract
--               rates. One row per invoice. Represents the
--               revenue side of SwiftRoute operations.
--
-- key facts:
--   - invoice_id: QuickBooks invoice Id (degenerate dimension,
--     kept for operational traceability).
--   - grain: one row per invoice.
--   - client_key: resolved from swiftroute_client_id in
--     QuickBooks CustomField, joining to dim_client.
--   - contract_rate_key: resolved from dim_contract_rate
--     matching on client and service_type from invoice
--     line item name. Best approximation since invoices
--     do not carry zone_id directly.
--   - invoice_amount: total invoice amount from QuickBooks.
--   - discount_amount: invoice_amount * discount_rate from
--     the client contract. Derived measure.
--   - payment_status: derived from balance. PAID if
--     balance = 0, PARTIAL if 0 < balance < invoice_amount,
--     UNPAID if balance = invoice_amount.
--   - payment_date: transaction_date from the linked payment
--     record in silver_quickbooks_payments.
--   - balance_remaining: outstanding balance from QuickBooks.
--   - invoice_number: document_number from QuickBooks.
--
-- incremental:  Append/upsert on invoice_id.
--
-- depends_on:   silver.silver_quickbooks_invoices
--               silver.silver_quickbooks_payments
--               dim_client
--               dim_contract_rate
--               dim_date
-- ============================================================

{{
    config(
        materialized='incremental',
        unique_key='invoice_id',
        on_schema_change='sync_all_columns',
        schema='gold_operations'
    )
}}

-- ============================================================
-- SECTION 1: BASE INVOICES FROM SILVER
-- ============================================================
WITH invoices AS (

    SELECT
        invoice_source_id,
        inv_qb_sk,
        document_number,
        swiftroute_client_id,
        customer_id,
        customer_name,
        billing_period,
        total_amount,
        balance,
        email_status,
        currency,
        payment_method,
        payment_terms,
        payment_terms_days,
        line_item_name,
        line_qty,
        line_unit_price,
        line_service_date,
        transaction_date,
        due_date,
        created_at,
        last_updated_at,
        is_paid,
        is_overdue,
        days_overdue,
        silver_loaded_at
    FROM {{ ref('silver_quickbooks_invoices') }}

    {% if is_incremental() %}
    WHERE silver_loaded_at > (
        SELECT MAX(created_ts) FROM {{ this }}
    )
    {% endif %}

),

-- ============================================================
-- SECTION 2: RESOLVE PAYMENT DATE FROM LINKED PAYMENTS
-- Join to silver_quickbooks_payments on linked_invoice_id
-- to get actual payment date for each invoice.
-- LEFT JOIN: unpaid invoices have no linked payment yet.
-- Where multiple payments exist for one invoice, take the
-- most recent payment date.
-- ============================================================
payments AS (

    SELECT
        linked_invoice_id,
        MAX(transaction_date)                                       AS payment_date,
        SUM(total_amount)                                           AS total_paid
    FROM {{ ref('silver_quickbooks_payments') }}
    WHERE linked_invoice_id IS NOT NULL
    GROUP BY linked_invoice_id

),

-- ============================================================
-- SECTION 3: RESOLVE CONTRACT RATE
-- Match on client and service_type derived from line item
-- name. Invoice line items follow pattern:
-- "Next-Day Delivery", "Same Day Delivery", "Standard Delivery"
-- Map to service_type keys: next_day, same_day, standard.
-- Use most recently effective rate per client and service.
-- ============================================================
rates_ranked AS (

    SELECT
        client_key,
        service_type,
        contract_rate_key,
        net_rate,
        effective_date,
        ROW_NUMBER() OVER (
            PARTITION BY client_key, service_type
            ORDER BY effective_date DESC
        )                                                           AS rate_rank
    FROM {{ ref('dim_contract_rate') }}

),

active_rates AS (

    SELECT
        client_key,
        service_type,
        contract_rate_key,
        net_rate
    FROM rates_ranked
    WHERE rate_rank = 1

),

-- ============================================================
-- SECTION 4: JOIN ALL DIMENSIONS
-- ============================================================
with_dimensions AS (

    SELECT
        i.*,

        -- payment resolution
        p.payment_date,
        p.total_paid,

        -- dim_client
        c.client_key,
        c.client_name,
        c.discount_rate                                             AS client_discount_rate,
        c.account_tier,

        -- service type derived from line item name
        CASE
            WHEN i.line_item_name ILIKE '%next%day%'    THEN 'next_day'
            WHEN i.line_item_name ILIKE '%same%day%'    THEN 'same_day'
            WHEN i.line_item_name ILIKE '%standard%'    THEN 'standard'
            ELSE NULL
        END                                                         AS derived_service_type,

        -- dim_contract_rate
        r.contract_rate_key,
        r.net_rate                                                  AS contracted_rate,

        -- dim_date (invoice transaction date)
        dd.date_key

    FROM invoices i

    LEFT JOIN payments p
        ON i.invoice_source_id = p.linked_invoice_id

    LEFT JOIN {{ ref('dim_client') }} c
        ON i.swiftroute_client_id = c.client_key

    LEFT JOIN active_rates r
        ON i.swiftroute_client_id = r.client_key
        AND CASE
            WHEN i.line_item_name ILIKE '%next%day%'    THEN 'next_day'
            WHEN i.line_item_name ILIKE '%same%day%'    THEN 'same_day'
            WHEN i.line_item_name ILIKE '%standard%'    THEN 'standard'
            ELSE NULL
        END = r.service_type

    LEFT JOIN {{ ref('dim_date') }} dd
        ON i.transaction_date = dd.full_date

),

-- ============================================================
-- SECTION 5: DERIVE FINAL MEASURES
-- ============================================================
final AS (

    SELECT
        -- -------------------------------------------------------
        -- degenerate dimension (operational traceability)
        -- -------------------------------------------------------
        invoice_source_id                                           AS invoice_id,
        inv_qb_sk,

        -- -------------------------------------------------------
        -- dimension keys (FKs to star schema)
        -- -------------------------------------------------------
        client_key,
        date_key,
        contract_rate_key,

        -- -------------------------------------------------------
        -- degenerate identifiers
        -- -------------------------------------------------------
        swiftroute_client_id,
        document_number                                             AS invoice_number,
        billing_period,
        derived_service_type                                        AS service_type,
        currency,
        payment_method,
        payment_terms,

        -- -------------------------------------------------------
        -- customer reference
        -- -------------------------------------------------------
        customer_id,
        customer_name,

        -- -------------------------------------------------------
        -- measures
        -- -------------------------------------------------------
        line_qty                                                    AS quantity,
        total_amount                                                AS invoice_amount,

        -- Derived: discount amount from client contract rate
        CASE
            WHEN client_discount_rate IS NOT NULL
            THEN ROUND(total_amount * client_discount_rate, 2)
            ELSE 0
        END                                                         AS discount_amount,

        -- Derived: net invoice amount after discount
        CASE
            WHEN client_discount_rate IS NOT NULL
            THEN ROUND(total_amount * (1 - client_discount_rate), 2)
            ELSE total_amount
        END                                                         AS net_invoice_amount,

        balance                                                     AS balance_remaining,

        -- Derived: payment status
        CASE
            WHEN balance = 0
            THEN 'Paid'
            WHEN balance > 0 AND balance < total_amount
            THEN 'Partial'
            WHEN balance = total_amount
            THEN 'Unpaid'
            ELSE 'Unknown'
        END                                                         AS payment_status,

        -- -------------------------------------------------------
        -- payment details
        -- -------------------------------------------------------
        payment_date,
        total_paid,
        is_paid,
        is_overdue,
        days_overdue,

        -- -------------------------------------------------------
        -- contracted rate reference
        -- -------------------------------------------------------
        contracted_rate,
        client_discount_rate,
        account_tier,

        -- -------------------------------------------------------
        -- dates
        -- -------------------------------------------------------
        transaction_date,
        due_date,
        created_at,
        last_updated_at,

        -- -------------------------------------------------------
        -- audit
        -- -------------------------------------------------------
        NOW()                                                       AS created_ts

    FROM with_dimensions

)

SELECT * FROM final