-- ============================================================
-- model:        silver_gusto_payroll_compensations
-- layer:        silver
-- source:       {{ source('bronze', 'gusto_payroll_compensations') }}
-- loaded_by:    loaders/load_gusto.py
-- description:  Cleaned and standardised per-employee payroll
--               compensation records from Gusto. Each record
--               represents one employee's compensation detail
--               within a single payroll run.
--
-- key facts:
--   - No single natural key exists in source. Surrogate key
--     cmp_sk generated. Record uniqueness is defined by the
--     combination of employee_uuid + payroll_uuid.
--   - employee_uuid links to silver_gusto_employees via
--     employee_source_id.
--   - payroll_uuid links to silver_gusto_payroll_runs via
--     payroll_source_id.
--   - taxes, benefits, deductions and fixed_compensations are
--     stored as JSONB arrays in bronze. First entries are
--     unpacked for common use cases. Full arrays retained
--     as JSONB for downstream flexibility.
--   - General Gusto fixes applied: empty strings to NULL,
--     derived columns computed not hardcoded.
--
-- incremental:  Upserts on MD5 of full row (record_hash_key).
--               Safe to re-run, existing records update.
--
-- depends_on:   bronze.gusto_payroll_compensations
--               silver.silver_gusto_employees
--               silver.silver_gusto_payroll_runs
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
    FROM {{ source('bronze', 'gusto_payroll_compensations') }}

    {% if is_incremental() %}
    WHERE ingest_timestamp > (
        SELECT MAX(silver_loaded_at) FROM {{ this }}
    )
    {% endif %}

),

-- ============================================================
-- SECTION 2: UNPACK
-- All field names verified against raw data samples.
-- Arrays unpacked at index 0 for common fields. Full arrays
-- retained as JSONB for downstream unnesting if needed.
-- ============================================================
unpacked AS (

    SELECT
        -- natural composite key
        raw_data ->> 'employee_uuid'                                AS employee_source_id,
        raw_data ->> 'payroll_uuid'                                 AS payroll_source_id,

        -- employee details
        raw_data ->> 'employee_first_name'                          AS first_name,
        raw_data ->> 'employee_last_name'                           AS last_name,
        raw_data ->> 'department'                                   AS department,

        -- compensation summary
        (raw_data ->> 'gross_pay')::NUMERIC                         AS gross_pay,
        (raw_data ->> 'net_pay')::NUMERIC                           AS net_pay,
        raw_data ->> 'payment_method'                               AS payment_method_raw,

        -- hours
        (raw_data ->> 'hours_worked')::NUMERIC                      AS hours_worked,
        (raw_data ->> 'overtime_hours')::NUMERIC                    AS overtime_hours,

        -- fixed compensations (first entry unpacked)
        (raw_data -> 'fixed_compensations' -> 0 ->> 'amount')::NUMERIC
                                                                    AS fixed_comp_amount,
        raw_data -> 'fixed_compensations' -> 0 ->> 'name'          AS fixed_comp_name,
        raw_data -> 'fixed_compensations'                           AS fixed_compensations_raw,

        -- taxes (full array retained, first entry unpacked)
        (raw_data -> 'taxes' -> 0 ->> 'amount')::NUMERIC            AS tax_1_amount,
        raw_data -> 'taxes' -> 0 ->> 'name'                         AS tax_1_name,
        (raw_data -> 'taxes' -> 0 ->> 'employer')::BOOLEAN          AS tax_1_is_employer,
        raw_data -> 'taxes'                                         AS taxes_raw,

        -- benefits (full array retained, first entry unpacked)
        raw_data -> 'benefits' -> 0 ->> 'name'                      AS benefit_1_name,
        (raw_data -> 'benefits' -> 0 ->> 'employee_deduction')::NUMERIC
                                                                    AS benefit_1_employee_deduction,
        (raw_data -> 'benefits' -> 0 ->> 'company_contribution')::NUMERIC
                                                                    AS benefit_1_company_contribution,
        raw_data -> 'benefits'                                      AS benefits_raw,

        -- employee deductions (full array retained, first entry unpacked)
        raw_data -> 'employee_deductions' -> 0 ->> 'name'           AS deduction_1_name,
        (raw_data -> 'employee_deductions' -> 0 ->> 'amount')::NUMERIC
                                                                    AS deduction_1_amount,
        (raw_data -> 'employee_deductions' -> 0 ->> 'pre_tax')::BOOLEAN
                                                                    AS deduction_1_pre_tax,
        raw_data -> 'employee_deductions'                           AS employee_deductions_raw,

        -- variable compensations (full array retained)
        raw_data -> 'variable_compensations'                        AS variable_compensations_raw,

        -- ods note
        raw_data ->> '_ods_note'                                    AS ods_note,

        bronze_ingest_timestamp

    FROM source

),

-- ============================================================
-- SECTION 3: CLEAN
-- ============================================================
cleaned AS (

    SELECT
        employee_source_id,
        payroll_source_id,
        NULLIF(TRIM(first_name), '')                                AS first_name,
        NULLIF(TRIM(last_name), '')                                 AS last_name,
        NULLIF(TRIM(department), '')                                AS department,
        gross_pay,
        net_pay,
        UPPER(NULLIF(TRIM(payment_method_raw), ''))                 AS payment_method,
        hours_worked,
        overtime_hours,
        fixed_comp_amount,
        NULLIF(TRIM(fixed_comp_name), '')                           AS fixed_comp_name,
        fixed_compensations_raw,
        tax_1_amount,
        NULLIF(TRIM(tax_1_name), '')                                AS tax_1_name,
        tax_1_is_employer,
        taxes_raw,
        NULLIF(TRIM(benefit_1_name), '')                            AS benefit_1_name,
        benefit_1_employee_deduction,
        benefit_1_company_contribution,
        benefits_raw,
        NULLIF(TRIM(deduction_1_name), '')                          AS deduction_1_name,
        deduction_1_amount,
        deduction_1_pre_tax,
        employee_deductions_raw,
        variable_compensations_raw,
        NULLIF(TRIM(ods_note), '')                                  AS ods_note,
        bronze_ingest_timestamp

    FROM unpacked

),

-- ============================================================
-- SECTION 4: DERIVE
-- ============================================================
derived AS (

    SELECT
        *,

        -- Derived: full name for cross-system joins
        TRIM(
            COALESCE(first_name, '') || ' ' || COALESCE(last_name, '')
        )                                                           AS full_name,

        -- Derived: total deductions (taxes + benefit deductions
        -- + employee deductions). Pipeline-safe: NULL-safe sum.
        ROUND(
            COALESCE(tax_1_amount, 0) +
            COALESCE(benefit_1_employee_deduction, 0) +
            COALESCE(deduction_1_amount, 0)
        , 2)                                                        AS total_deductions_approx,

        -- Derived: effective hourly rate (gross pay / hours worked)
        -- NULL-safe: only computed when hours_worked > 0
        CASE
            WHEN hours_worked IS NOT NULL AND hours_worked > 0
            THEN ROUND(gross_pay / hours_worked, 2)
            ELSE NULL
        END                                                         AS effective_hourly_rate,

        -- Derived: overtime flag
        CASE
            WHEN overtime_hours IS NOT NULL AND overtime_hours > 0
            THEN TRUE
            ELSE FALSE
        END                                                         AS has_overtime

    FROM cleaned

),

-- ============================================================
-- SECTION 5: JOIN to employees and payroll runs
-- LEFT JOIN on both: preserves records where UUID resolution
-- fails (edge case only, data should always resolve).
-- ============================================================
with_refs AS (

    SELECT
        d.*,
        e.emp_sk,
        e.job_title,
        e.employment_status,
        e.is_active                                                 AS employee_is_active,
        p.pay_sk,
        p.check_date,
        p.pay_period_start,
        p.pay_period_end
    FROM derived d
    LEFT JOIN {{ ref('silver_gusto_employees') }} e
        ON d.employee_source_id = e.employee_source_id
    LEFT JOIN {{ ref('silver_gusto_payroll_runs') }} p
        ON d.payroll_source_id = p.payroll_source_id

),

-- ============================================================
-- SECTION 6: SURROGATE KEY + SILVER METADATA
-- cmp_sk: human-readable surrogate (cmp_00001, cmp_00002 ...)
-- record_hash_key: MD5 of full row for incremental upserts
-- ============================================================
final AS (

    SELECT
        -- -------------------------------------------------------
        -- surrogate key
        -- -------------------------------------------------------
        'cmp_' || LPAD(
            ROW_NUMBER() OVER (
                ORDER BY payroll_source_id ASC, employee_source_id ASC
            )::TEXT
        , 5, '0')                                                   AS cmp_sk,

        -- -------------------------------------------------------
        -- natural composite key (no single PK in source)
        -- -------------------------------------------------------
        employee_source_id,
        payroll_source_id,

        -- -------------------------------------------------------
        -- dbt incremental unique key
        -- -------------------------------------------------------
        MD5(
            COALESCE(employee_source_id, '')        ||
            COALESCE(payroll_source_id, '')         ||
            COALESCE(gross_pay::TEXT, '')           ||
            COALESCE(net_pay::TEXT, '')             ||
            COALESCE(hours_worked::TEXT, '')        ||
            COALESCE(payment_method, '')
        )                                                           AS record_hash_key,

        -- -------------------------------------------------------
        -- employee reference
        -- -------------------------------------------------------
        emp_sk,
        full_name,
        first_name,
        last_name,
        department,
        job_title,
        employment_status,
        employee_is_active,

        -- -------------------------------------------------------
        -- payroll run reference
        -- -------------------------------------------------------
        pay_sk,
        check_date,
        pay_period_start,
        pay_period_end,

        -- -------------------------------------------------------
        -- compensation summary
        -- -------------------------------------------------------
        gross_pay,
        net_pay,
        payment_method,
        total_deductions_approx,
        effective_hourly_rate,

        -- -------------------------------------------------------
        -- hours
        -- -------------------------------------------------------
        hours_worked,
        overtime_hours,
        has_overtime,

        -- -------------------------------------------------------
        -- fixed compensations
        -- -------------------------------------------------------
        fixed_comp_name,
        fixed_comp_amount,
        fixed_compensations_raw,

        -- -------------------------------------------------------
        -- taxes
        -- -------------------------------------------------------
        tax_1_name,
        tax_1_amount,
        tax_1_is_employer,
        taxes_raw,

        -- -------------------------------------------------------
        -- benefits
        -- -------------------------------------------------------
        benefit_1_name,
        benefit_1_employee_deduction,
        benefit_1_company_contribution,
        benefits_raw,

        -- -------------------------------------------------------
        -- deductions
        -- -------------------------------------------------------
        deduction_1_name,
        deduction_1_amount,
        deduction_1_pre_tax,
        employee_deductions_raw,

        -- -------------------------------------------------------
        -- variable compensations
        -- -------------------------------------------------------
        variable_compensations_raw,

        -- -------------------------------------------------------
        -- notes
        -- -------------------------------------------------------
        ods_note,

        -- -------------------------------------------------------
        -- silver metadata
        -- -------------------------------------------------------
        NOW()                                                       AS silver_loaded_at,
        'silver_gusto_payroll_compensations'                        AS silver_source_model

    FROM with_refs

)

SELECT * FROM final