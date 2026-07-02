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

select
    -- metadata columns added by the loader
    id                                              as bronze_row_id,
    ingest_timestamp                                as bronze_ingest_timestamp,
    source_file                                     as bronze_source_file,

    -- core payroll identifiers
    raw_data ->> 'uuid'                             as payroll_id,
    (raw_data ->> 'check_date')::date               as check_date,

    -- pay period
    raw_data -> 'pay_period' ->> 'start_date'       as pay_period_start,
    raw_data -> 'pay_period' ->> 'end_date'         as pay_period_end,

    -- totals
    (raw_data -> 'totals' ->> 'gross_pay')::numeric     as gross_pay,
    (raw_data -> 'totals' ->> 'net_pay')::numeric       as net_pay,
    (raw_data -> 'totals' ->> 'employee_taxes')::numeric as employee_taxes,
    (raw_data -> 'totals' ->> 'employer_taxes')::numeric as employer_taxes,

    -- raw data for reference
    raw_data

from bronze.gusto_payroll_runs

order by ingest_timestamp desc, bronze_row_id desc