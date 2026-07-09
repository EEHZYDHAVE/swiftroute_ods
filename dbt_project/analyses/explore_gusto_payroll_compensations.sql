-- =============================================================================
-- analysis: explore_gusto_payroll_compensations.sql
-- purpose:  Unpack raw JSONB from bronze.gusto_payroll_compensations into
--           readable columns for exploratory review before writing silver model.
--
-- layer:    bronze (read only — no data is created or modified)
-- schema:   bronze
-- source:   bronze.gusto_payroll_compensations (loaded by loaders/load_gusto.py)
--
-- usage:    Run via dbt Power User preview or psql session.
--           Not materialized — analysis files never create database objects.
-- =============================================================================

SELECT
    -- metadata
    id                                              AS bronze_row_id,
    ingest_timestamp                                AS bronze_ingest_timestamp,
    source_file                                     AS bronze_source_file,

    -- core identifiers
    raw_data ->> 'employee_uuid'                    AS employee_id,
    raw_data ->> 'payroll_uuid'                     AS payroll_id,

    -- employee details
    raw_data ->> 'employee_first_name'              AS first_name,
    raw_data ->> 'employee_last_name'               AS last_name,
    raw_data ->> 'department'                       AS department,

    -- compensation summary
    (raw_data ->> 'gross_pay')::numeric             AS gross_pay,
    (raw_data ->> 'net_pay')::numeric               AS net_pay,
    raw_data ->> 'payment_method'                   AS payment_method,

    -- hours
    (raw_data ->> 'hours_worked')::numeric          AS hours_worked,
    (raw_data ->> 'overtime_hours')::numeric        AS overtime_hours,

    -- taxes (full array for reference)
    raw_data -> 'taxes'                             AS taxes,
    -- example: first tax entry
    raw_data -> 'taxes' -> 0 ->> 'name'             AS tax_1_name,
    (raw_data -> 'taxes' -> 0 ->> 'amount')::numeric AS tax_1_amount,
    (raw_data -> 'taxes' -> 0 ->> 'employer')::boolean AS tax_1_employer_flag,

    -- benefits (full array for reference)
    raw_data -> 'benefits'                          AS benefits,
    raw_data -> 'benefits' -> 0 ->> 'name'          AS benefit_1_name,
    (raw_data -> 'benefits' -> 0 ->> 'employee_deduction')::numeric AS benefit_1_employee_deduction,
    (raw_data -> 'benefits' -> 0 ->> 'company_contribution')::numeric AS benefit_1_company_contribution,

    -- employee deductions (full array for reference)
    raw_data -> 'employee_deductions'               AS employee_deductions,
    raw_data -> 'employee_deductions' -> 0 ->> 'name' AS deduction_1_name,
    (raw_data -> 'employee_deductions' -> 0 ->> 'amount')::numeric AS deduction_1_amount,
    (raw_data -> 'employee_deductions' -> 0 ->> 'pre_tax')::boolean AS deduction_1_pre_tax,

    -- fixed compensations (full array for reference)
    raw_data -> 'fixed_compensations'               AS fixed_compensations,
    raw_data -> 'fixed_compensations' -> 0 ->> 'name' AS fixed_comp_name,
    (raw_data -> 'fixed_compensations' -> 0 ->> 'amount')::numeric AS fixed_comp_amount,
    raw_data -> 'fixed_compensations' -> 0 ->> 'job_uuid' AS fixed_comp_job_id,

    -- variable compensations
    raw_data -> 'variable_compensations'            AS variable_compensations,

    -- notes
    raw_data ->> '_ods_note'                        AS ods_note,

    -- raw JSON
    raw_data
FROM bronze.gusto_payroll_compensations
ORDER BY ingest_timestamp DESC, bronze_row_id DESC;


RAW DATA:


RAW DATA:
{
  "taxes": [
    {
      "name": "Federal Income Tax",
      "amount": "293.01",
      "employer": false
    },
    {
      "name": "Social Security",
      "amount": "159.82",
      "employer": false
    },
    {
      "name": "Medicare",
      "amount": "79.91",
      "employer": false
    }
  ],
  "benefits": [
    {
      "name": "Medical Insurance",
      "imputed": false,
      "employee_deduction": "175.09",
      "company_contribution": "113.81"
    }
  ],
  "_ods_note": "Labour cost for this employee this period: $3712.46 gross + $406.51 employer taxes = $4118.97 true cost. Delivery count must be sourced from Onfleet — it does not exist anywhere in this file.",
  "department": "Leadership",
  "employee_uuid": "b605ae51-80e1-4032-98bc-1240a60a542e",
  "paid_time_off": [],
  "employee_last_name": "Reynolds",
  "employee_deductions": [
    {
      "name": "401(k) Employee Contribution",
      "amount": "111.37",
      "pre_tax": true
    }
  ],
  "employee_first_name": "Erica",
  "fixed_compensations": [
    {
      "name": "Regular Pay",
      "amount": "3712.46",
      "job_uuid": "ecf359e9-383a-471f-8c41-a91e667d6f3c"
    }
  ],
  "variable_compensations": []
}