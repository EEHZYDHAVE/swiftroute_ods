-- ============================================================
-- model:        silver_gusto_payroll_runs
-- layer:        silver
-- source:       {{ source('bronze', 'gusto_payroll_runs') }}
-- loaded_by:    loaders/load_gusto.py
-- description:  Cleaned and standardised payroll run records
--               from Gusto. Each record represents one payroll
--               run covering a specific pay period.
--
-- key facts:
--   - uuid retained as payroll_source_id. Surrogate key
--     pay_sk generated.
--   - payroll_source_id is the join key to
--     silver_gusto_payroll_compensations.
--   - QUIRK 3 (documented in source): pay period may end on
--     June 30 but check_date lands on July 3. This is not a
--     data quality error, it reflects real payroll timing.
--     Both dates are kept and the quirk is documented here.
--   - QUIRK 6 (documented in source): company_debit =
--     gross_pay + employer_taxes. This is by design.
--   - All timestamps to TIMESTAMPTZ.
--   - All empty strings to NULL.
--   - General Gusto fixes applied: empty strings to NULL,
--     derived columns computed not hardcoded.
--
-- incremental:  Upserts on MD5 of full row (record_hash_key).
--               Safe to re-run, existing records update.
--
-- depends_on:   bronze.gusto_payroll_runs
-- ============================================================

{{
    config(
        materialized='incremental',
        unique_key='record_hash_key',
        on_schema_change='sync_all_columns'
    )
}}

-- ============================================================
-- SECTION 1: SOURCE
-- ============================================================
WITH source AS (

    SELECT
        id                  AS bronze_row_id,
        ingest_timestamp    AS bronze_ingest_timestamp,
        raw_data
    FROM {{ source('bronze', 'gusto_payroll_runs') }}

    {% if is_incremental() %}
    WHERE ingest_timestamp > (
        SELECT MAX(silver_loaded_at) FROM {{ this }}
    )
    {% endif %}

),

-- ============================================================
-- SECTION 2: UNPACK
-- All field names verified against raw data samples.
-- ============================================================
unpacked AS (

    SELECT
        -- natural key
        raw_data ->> 'uuid'                                         AS payroll_source_id,
        raw_data ->> 'version'                                      AS version,
        (raw_data ->> 'processed')::BOOLEAN                         AS is_processed,

        -- company identifiers
        raw_data ->> 'company_id'                                   AS company_id,
        raw_data ->> 'company_uuid'                                 AS company_uuid,

        -- dates
        (raw_data ->> 'check_date')::DATE                           AS check_date,
        (raw_data ->> 'payroll_deadline')::DATE                     AS payroll_deadline,

        -- pay period
        (raw_data -> 'pay_period' ->> 'start_date')::DATE           AS pay_period_start,
        (raw_data -> 'pay_period' ->> 'end_date')::DATE             AS pay_period_end,

        -- totals
        (raw_data -> 'totals' ->> 'gross_pay')::NUMERIC             AS gross_pay,
        (raw_data -> 'totals' ->> 'net_pay')::NUMERIC               AS net_pay,
        (raw_data -> 'totals' ->> 'employee_taxes')::NUMERIC        AS employee_taxes,
        (raw_data -> 'totals' ->> 'employer_taxes')::NUMERIC        AS employer_taxes,
        (raw_data -> 'totals' ->> 'employee_deductions')::NUMERIC   AS employee_deductions,
        (raw_data -> 'totals' ->> 'company_debit')::NUMERIC         AS company_debit,

        bronze_ingest_timestamp

    FROM source

),

-- ============================================================
-- SECTION 3: CLEAN
-- ============================================================
cleaned AS (

    SELECT
        payroll_source_id,
        NULLIF(TRIM(version), '')                                   AS version,
        is_processed,
        NULLIF(TRIM(company_id), '')                                AS company_id,
        NULLIF(TRIM(company_uuid), '')                              AS company_uuid,
        check_date,
        payroll_deadline,
        pay_period_start,
        pay_period_end,
        gross_pay,
        net_pay,
        employee_taxes,
        employer_taxes,
        employee_deductions,
        company_debit,
        bronze_ingest_timestamp

    FROM unpacked

),

-- ============================================================
-- SECTION 4: DERIVE
-- ============================================================
derived AS (

    SELECT
        *,

        -- Derived: pay period duration in days
        CASE
            WHEN pay_period_start IS NOT NULL AND pay_period_end IS NOT NULL
            THEN (pay_period_end - pay_period_start) + 1
            ELSE NULL
        END                                                         AS pay_period_days,

        -- Derived: days between period end and check date
        -- Documents the QUIRK 3 timing lag (e.g. period ends
        -- June 30, check issued July 3 = 3 days lag).
        -- Pipeline-safe: computed from actual dates, not hardcoded.
        CASE
            WHEN check_date IS NOT NULL AND pay_period_end IS NOT NULL
            THEN (check_date - pay_period_end)
            ELSE NULL
        END                                                         AS check_date_lag_days,

        -- Derived: total labour cost to company
        -- = gross_pay + employer_taxes (QUIRK 6: this equals company_debit)
        CASE
            WHEN gross_pay IS NOT NULL AND employer_taxes IS NOT NULL
            THEN ROUND(gross_pay + employer_taxes, 2)
            ELSE NULL
        END                                                         AS total_labour_cost,

        -- Derived: effective tax rate (employee taxes as % of gross)
        CASE
            WHEN gross_pay IS NOT NULL
            AND gross_pay > 0
            AND employee_taxes IS NOT NULL
            THEN ROUND((employee_taxes / gross_pay) * 100, 2)
            ELSE NULL
        END                                                         AS effective_employee_tax_rate_pct

    FROM cleaned

),

-- ============================================================
-- SECTION 5: SURROGATE KEY + SILVER METADATA
-- pay_sk: human-readable surrogate (pay_00001, pay_00002 ...)
-- record_hash_key: MD5 of full row for incremental upserts
-- ============================================================
final AS (

    SELECT
        -- -------------------------------------------------------
        -- surrogate key
        -- -------------------------------------------------------
        'pay_' || LPAD(
            ROW_NUMBER() OVER (ORDER BY check_date ASC)::TEXT
        , 5, '0')                                                   AS pay_sk,

        -- -------------------------------------------------------
        -- natural key
        -- -------------------------------------------------------
        payroll_source_id,

        -- -------------------------------------------------------
        -- dbt incremental unique key
        -- -------------------------------------------------------
        MD5(
            COALESCE(payroll_source_id, '')         ||
            COALESCE(check_date::TEXT, '')          ||
            COALESCE(gross_pay::TEXT, '')           ||
            COALESCE(net_pay::TEXT, '')             ||
            COALESCE(company_debit::TEXT, '')       ||
            COALESCE(is_processed::TEXT, '')
        )                                                           AS record_hash_key,

        -- -------------------------------------------------------
        -- company
        -- -------------------------------------------------------
        company_id,
        company_uuid,

        -- -------------------------------------------------------
        -- payroll status
        -- -------------------------------------------------------
        is_processed,
        version,

        -- -------------------------------------------------------
        -- pay period
        -- -------------------------------------------------------
        pay_period_start,
        pay_period_end,
        pay_period_days,
        check_date,
        payroll_deadline,
        check_date_lag_days,

        -- -------------------------------------------------------
        -- financials
        -- -------------------------------------------------------
        gross_pay,
        net_pay,
        employee_taxes,
        employer_taxes,
        employee_deductions,
        company_debit,
        total_labour_cost,
        effective_employee_tax_rate_pct,

        -- -------------------------------------------------------
        -- silver metadata
        -- -------------------------------------------------------
        NOW()                                                       AS silver_loaded_at,
        'silver_gusto_payroll_runs'                                 AS silver_source_model

    FROM derived

)

SELECT * FROM final