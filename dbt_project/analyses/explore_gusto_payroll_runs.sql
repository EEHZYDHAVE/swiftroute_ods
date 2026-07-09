-- =============================================================================
-- analysis: explore_gusto_payroll_runs.sql
-- purpose:  Unpack raw JSONB from bronze.gusto_payroll_runs into readable
--           columns for exploratory review before writing the silver model.
--
-- layer:    bronze (read only, no data is created or modified)
-- schema:   bronze
-- source:   bronze.gusto_payroll_runs (loaded by loaders/load_gusto.py)
--
-- usage:    Run via dbt Power User preview or psql session.
--           Not materialized, analysis files never create database objects.
-- =============================================================================

SELECT
    -- metadata
    id                                              AS bronze_row_id,
    ingest_timestamp                                AS bronze_ingest_timestamp,
    source_file                                     AS bronze_source_file,

    -- core payroll identifiers
    raw_data ->> 'uuid'                             AS payroll_id,
    raw_data ->> 'version'                          AS version,
    (raw_data ->> 'processed')::boolean             AS is_processed,
    (raw_data ->> 'check_date')::date               AS check_date,
    (raw_data ->> 'payroll_deadline')::date         AS payroll_deadline,

    -- company identifiers
    raw_data ->> 'company_id'                       AS company_id,
    raw_data ->> 'company_uuid'                     AS company_uuid,

    -- pay period
    raw_data -> 'pay_period' ->> 'start_date'       AS pay_period_start,
    raw_data -> 'pay_period' ->> 'end_date'         AS pay_period_end,
    raw_data -> 'pay_period' ->> '_note'            AS pay_period_note,

    -- totals
    (raw_data -> 'totals' ->> 'gross_pay')::numeric     AS gross_pay,
    (raw_data -> 'totals' ->> 'net_pay')::numeric       AS net_pay,
    (raw_data -> 'totals' ->> 'employee_taxes')::numeric AS employee_taxes,
    (raw_data -> 'totals' ->> 'employer_taxes')::numeric AS employer_taxes,
    (raw_data -> 'totals' ->> 'employee_deductions')::numeric AS employee_deductions,
    (raw_data -> 'totals' ->> 'company_debit')::numeric AS company_debit,
    raw_data -> 'totals' ->> '_note'                AS totals_note,

    -- raw JSON
    raw_data
FROM bronze.gusto_payroll_runs
ORDER BY ingest_timestamp DESC, bronze_row_id DESC;



RAW DATA:
{
  "uuid": "42f882a3-2ee9-440b-acc9-d6f13fedbba1",
  "totals": {
    "_note": "QUIRK 6: company_debit = gross_pay + employer_taxes.",
    "net_pay": "106092.85",
    "gross_pay": "134714.55",
    "company_debit": "149465.78",
    "employee_taxes": "19331.54",
    "employer_taxes": "14751.23",
    "employee_deductions": "9290.16"
  },
  "version": "f726caa8-716d-4a4d-830a-2a5e19f96656",
  "processed": true,
  "check_date": "2025-07-03",
  "company_id": "8847392",
  "pay_period": {
    "_note": "QUIRK 3: period ended 2025-06-30 but money leaves accounts on 2025-07-03.",
    "end_date": "2025-06-30",
    "start_date": "2025-06-18"
  },
  "company_uuid": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "payroll_deadline": "2025-07-03"
}