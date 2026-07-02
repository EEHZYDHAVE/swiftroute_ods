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

select
    -- metadata columns added by the loader
    id                                              as bronze_row_id,
    ingest_timestamp                                as bronze_ingest_timestamp,
    source_file                                     as bronze_source_file,

    -- core employee identifiers
    raw_data ->> 'uuid'                             as employee_id,
    raw_data ->> 'employee_number'                  as employee_number,

    -- personal details
    raw_data ->> 'first_name'                       as first_name,
    raw_data ->> 'last_name'                        as last_name,
    raw_data ->> 'email'                            as email,
    raw_data ->> 'phone'                            as phone,

    -- employment details
    raw_data ->> 'department'                       as department,
    raw_data ->> 'job_title'                        as job_title,
    (raw_data ->> 'start_date')::date               as start_date,
    (raw_data ->> 'termination_date')::date         as termination_date,
    (raw_data ->> 'active')::boolean                as is_active,

    -- compensation
    raw_data ->> 'payment_method'                   as payment_method,

    -- raw data for reference
    raw_data

from bronze.gusto_employees

order by ingest_timestamp desc, bronze_row_id desc