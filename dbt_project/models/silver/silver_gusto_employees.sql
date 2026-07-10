-- ============================================================
-- model:        silver_gusto_employees
-- layer:        silver
-- source:       {{ source('bronze', 'gusto_employees') }}
-- loaded_by:    loaders/load_gusto.py
-- description:  Cleaned and standardised employee records from
--               Gusto HR system. This is the AUTHORITATIVE source
--               for employee identity across the pipeline.
--
-- key facts:
--   - uuid (Gusto's natural key) is retained as employee_source_id.
--   - A human-readable surrogate key (emp_sk) is generated.
--   - Cross-system joins to Samsara and Onfleet are done via
--     employee name where UUID mapping does not exist.
--   - One employee has a non-null termination_date: this is
--     intentional and canonical across all source systems.
--   - _is_driver flag identifies employees who also appear in
--     Onfleet and Samsara as drivers.
--   - General fixes applied: empty strings → NULL,
--     timestamps → TIMESTAMPTZ, derived columns computed.
--
-- incremental:  Upserts on MD5 of full row (record_hash_key).
--               Safe to re-run: existing records update in place.
--
-- depends_on:   bronze.gusto_employees
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
    FROM {{ source('bronze', 'gusto_employees') }}

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
        raw_data ->> 'uuid'                                         AS employee_source_id,
        raw_data ->> 'company_id'                                   AS company_id,
        raw_data ->> 'company_uuid'                                 AS company_uuid,

        -- personal details
        raw_data ->> 'first_name'                                   AS first_name,
        raw_data ->> 'last_name'                                    AS last_name,
        raw_data ->> 'email'                                        AS email,
        raw_data ->> 'phone'                                        AS phone,
        (raw_data ->> 'date_of_birth')::DATE                        AS date_of_birth,

        -- employment
        raw_data ->> 'department'                                   AS department,
        raw_data ->> '_dept'                                        AS dept_internal,
        raw_data -> 'job' ->> 'title'                               AS job_title,
        (raw_data -> 'job' ->> 'hire_date')::DATE                   AS hire_date,
        raw_data ->> 'employment_status'                            AS employment_status_raw,
        (raw_data ->> 'termination_date')::DATE                     AS termination_date,

        -- compensation
        (raw_data -> 'job' ->> 'rate')::NUMERIC                     AS job_rate,
        raw_data -> 'job' ->> 'payment_unit'                        AS payment_unit,
        (raw_data ->> '_annual_salary')::NUMERIC                    AS annual_salary,
        (raw_data ->> '_bi_weekly_gross')::NUMERIC                  AS bi_weekly_gross,
        (raw_data ->> '_bonus_max')::NUMERIC                        AS bonus_max,
        raw_data ->> 'payment_method'                               AS payment_method_raw,

        -- flags
        (raw_data ->> '_is_driver')::BOOLEAN                        AS is_driver,
        (raw_data ->> 'active')::BOOLEAN                            AS is_active_raw,

        -- bronze metadata
        bronze_ingest_timestamp

    FROM source

),

-- ============================================================
-- SECTION 3: CLEAN: nulls, empty strings, standardisation
-- ============================================================
cleaned AS (

    SELECT
        employee_source_id,
        NULLIF(TRIM(company_id), '')                                AS company_id,
        NULLIF(TRIM(company_uuid), '')                              AS company_uuid,

        -- personal
        NULLIF(TRIM(first_name), '')                                AS first_name,
        NULLIF(TRIM(last_name), '')                                 AS last_name,
        LOWER(NULLIF(TRIM(email), ''))                              AS email,
        NULLIF(TRIM(phone), '')                                     AS phone,
        date_of_birth,

        -- employment
        NULLIF(TRIM(department), '')                                AS department,
        NULLIF(TRIM(dept_internal), '')                             AS dept_internal,
        NULLIF(TRIM(job_title), '')                                 AS job_title,
        hire_date,
        NULLIF(TRIM(employment_status_raw), '')                     AS employment_status,
        termination_date,

        -- compensation
        job_rate,
        NULLIF(TRIM(payment_unit), '')                              AS payment_unit,
        annual_salary,
        bi_weekly_gross,
        bonus_max,
        UPPER(NULLIF(TRIM(payment_method_raw), ''))                 AS payment_method,

        -- flags
        is_driver,
        is_active_raw,

        bronze_ingest_timestamp

    FROM unpacked

),

-- ============================================================
-- SECTION 4: DERIVE: computed/enriched columns
-- ============================================================
derived AS (

    SELECT
        *,

        -- Derived: full name for cross-system joins
        -- (Samsara and Onfleet join on name where UUID unavailable)
        TRIM(
            COALESCE(first_name, '') || ' ' || COALESCE(last_name, '')
        )                                                           AS full_name,

        -- Derived: is employee currently active?
        -- Canonical rule: active if no termination date AND
        -- employment_status = 'Active'. Both conditions must hold.
        CASE
            WHEN termination_date IS NULL
            AND UPPER(employment_status) = 'ACTIVE'
            THEN TRUE
            ELSE FALSE
        END                                                         AS is_active,

        -- Derived: years of service (from hire date to today,
        -- or to termination date if terminated)
        -- Pipeline-safe: uses current_date, not a hardcoded date.
        ROUND(
            (COALESCE(termination_date, CURRENT_DATE) - hire_date) / 365.25
        , 1)                                                        AS years_of_service,

        -- Derived: employment type label from employment_status
        CASE
            WHEN UPPER(employment_status) = 'ACTIVE'      THEN 'Active'
            WHEN UPPER(employment_status) = 'TERMINATED'  THEN 'Terminated'
            ELSE 'Unknown'
        END                                                         AS employment_status_label

    FROM cleaned

),

-- ============================================================
-- SECTION 5: SURROGATE KEY + SILVER METADATA
-- emp_sk: human-readable surrogate (emp_00001, emp_00002 ...)
-- record_hash_key: MD5 of full row for incremental upserts
-- ============================================================
final AS (

    SELECT
        -- -------------------------------------------------------
        -- surrogate key
        -- -------------------------------------------------------
        'emp_' || LPAD(
            ROW_NUMBER() OVER (ORDER BY employee_source_id)::TEXT, 5, '0'
        )                                                           AS emp_sk,

        -- -------------------------------------------------------
        -- natural key (Gusto UUID: retained for reference)
        -- -------------------------------------------------------
        employee_source_id,

        -- -------------------------------------------------------
        -- dbt incremental unique key
        -- -------------------------------------------------------
        MD5(
            COALESCE(employee_source_id, '')    ||
            COALESCE(full_name, '')             ||
            COALESCE(employment_status, '')     ||
            COALESCE(termination_date::TEXT, '')||
            COALESCE(job_title, '')             ||
            COALESCE(annual_salary::TEXT, '')   ||
            COALESCE(is_active::TEXT, '')
        )                                                           AS record_hash_key,

        -- -------------------------------------------------------
        -- identity
        -- -------------------------------------------------------
        full_name,
        first_name,
        last_name,
        email,
        phone,
        date_of_birth,

        -- -------------------------------------------------------
        -- employment
        -- -------------------------------------------------------
        company_id,
        company_uuid,
        department,
        dept_internal,
        job_title,
        hire_date,
        termination_date,
        employment_status,
        employment_status_label,
        is_active,
        is_driver,
        years_of_service,

        -- -------------------------------------------------------
        -- compensation
        -- -------------------------------------------------------
        job_rate,
        payment_unit,
        annual_salary,
        bi_weekly_gross,
        bonus_max,
        payment_method,

        -- -------------------------------------------------------
        -- silver metadata
        -- -------------------------------------------------------
        NOW()                                                       AS silver_loaded_at,
        'silver_gusto_employees'                                    AS silver_source_model

    FROM derived

)

SELECT * FROM final