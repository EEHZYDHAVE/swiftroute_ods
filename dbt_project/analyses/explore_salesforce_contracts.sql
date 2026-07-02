-- =============================================================================
-- analysis: explore_salesforce_contracts.sql
-- purpose:  Unpack raw JSONB from bronze.salesforce_contracts into readable
--           columns for exploratory review before writing the silver model.
--
-- layer:    bronze (read only, no data is created or modified)
-- schema:   bronze
-- source:   bronze.salesforce_contracts (loaded by loaders/load_salesforce.py)
--
-- usage:    Run via dbt Power User preview or psql session.
--           Not materialized, analysis files never create database objects.
-- =============================================================================

select
    -- metadata columns added by the loader
    id                                              as bronze_row_id,
    ingest_timestamp                                as bronze_ingest_timestamp,
    source_file                                     as bronze_source_file,

    -- core contract identifiers
    raw_data ->> 'Id'                               as contract_id,
    raw_data ->> 'ContractNumber'                   as contract_number,
    raw_data ->> 'Name'                             as contract_name,

    -- account reference
    raw_data -> 'AccountId' ->> 'value'             as account_id,

    -- dates
    (raw_data ->> 'StartDate')::date                as start_date,
    (raw_data ->> 'EndDate')::date                  as end_date,

    -- status
    raw_data ->> 'Status'                           as status,

    -- terms
    (raw_data ->> 'ContractTerm')::int              as contract_term_months,
    raw_data ->> 'Description'                      as description,

    -- raw data for reference
    raw_data

from bronze.salesforce_contracts

order by ingest_timestamp desc, bronze_row_id desc