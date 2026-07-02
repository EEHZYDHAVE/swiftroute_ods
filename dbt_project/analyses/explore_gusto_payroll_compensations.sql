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

select
    -- metadata columns added by the loader
    id                                                  as bronze_row_id,
    ingest_timestamp                                    as bronze_ingest_timestamp,
    source_file                                         as bronze_source_file,

    -- core identifiers
    raw_data ->> 'employee_uuid'                        as employee_id,
    raw_data ->> 'payroll_uuid'                         as payroll_id,

    -- compensation details
    (raw_data ->> 'gross_pay')::numeric                 as gross_pay,
    (raw_data ->> 'net_pay')::numeric                   as net_pay,
    (raw_data ->> 'payment_method')::text               as payment_method,

    -- hours
    (raw_data ->> 'hours_worked')::numeric              as hours_worked,
    (raw_data ->> 'overtime_hours')::numeric            as overtime_hours,

    -- taxes
    (raw_data ->> 'employee_taxes')::numeric            as employee_taxes,
    (raw_data ->> 'employer_taxes')::numeric            as employer_taxes,

    -- raw data for reference
    raw_data

from bronze.gusto_payroll_compensations

order by ingest_timestamp desc, bronze_row_id desc