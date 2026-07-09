-- =============================================================================
-- analysis: explore_gusto_employees.sql
-- purpose:  Unpack raw JSONB from bronze.gusto_employees into readable
--           columns for exploratory review before writing the silver model.
--
-- layer:    bronze (read only, no data is created or modified)
-- schema:   bronze
-- source:   bronze.gusto_employees (loaded by loaders/load_gusto.py)
--
-- usage:    Run via dbt Power User preview or psql session.
--           Not materialized, analysis files never create database objects.
-- =============================================================================

SELECT
    -- metadata
    id                                              AS bronze_row_id,
    ingest_timestamp                                AS bronze_ingest_timestamp,
    source_file                                     AS bronze_source_file,

    -- core identifiers
    raw_data ->> 'uuid'                             AS employee_id,
    raw_data ->> 'company_id'                       AS company_id,
    raw_data ->> 'company_uuid'                     AS company_uuid,

    -- personal details
    raw_data ->> 'first_name'                       AS first_name,
    raw_data ->> 'last_name'                        AS last_name,
    raw_data ->> 'email'                            AS email,
    raw_data ->> 'phone'                            AS phone,
    (raw_data ->> 'date_of_birth')::date            AS date_of_birth,

    -- employment details
    raw_data ->> 'department'                       AS department,
    raw_data ->> '_dept'                            AS dept_internal,
    raw_data -> 'job' ->> 'title'                   AS job_title,
    (raw_data -> 'job' ->> 'hire_date')::date       AS hire_date,
    raw_data ->> 'employment_status'                AS employment_status,
    (raw_data ->> 'termination_date')::date         AS termination_date,

    -- compensation
    (raw_data -> 'job' ->> 'rate')::numeric         AS job_rate,
    raw_data -> 'job' ->> 'payment_unit'            AS payment_unit,
    (raw_data ->> '_annual_salary')::numeric        AS annual_salary,
    (raw_data ->> '_bi_weekly_gross')::numeric      AS bi_weekly_gross,
    (raw_data ->> '_bonus_max')::numeric            AS bonus_max,
    raw_data ->> 'payment_method'                   AS payment_method,

    -- flags
    (raw_data ->> '_is_driver')::boolean            AS is_driver,
    (raw_data ->> 'active')::boolean                AS is_active,

    -- custom fields
    raw_data -> 'custom_fields'                     AS custom_fields,

    -- raw JSON
    raw_data
FROM bronze.gusto_employees
ORDER BY ingest_timestamp DESC, bronze_row_id DESC;


RAW DATA:
{
  "job": {
    "rate": "3712.46",
    "title": "City Operations Manager — SLC",
    "hire_date": "2021-04-29",
    "payment_unit": "Paycheck"
  },
  "uuid": "b605ae51-80e1-4032-98bc-1240a60a542e",
  "_dept": "Leadership",
  "email": "abrown@example.net",
  "phone": "001-518-864-1199x569",
  "last_name": "Reynolds",
  "_bonus_max": 0,
  "_is_driver": false,
  "company_id": "8847392",
  "department": "Leadership",
  "first_name": "Erica",
  "company_uuid": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "custom_fields": [],
  "date_of_birth": "1990-12-18",
  "_annual_salary": 96524,
  "_bi_weekly_gross": 3712.46,
  "termination_date": null,
  "employment_status": "Active"
}