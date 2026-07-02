-- =============================================================================
-- analysis: explore_salesforce_contract_rates.sql
-- purpose:  Unpack raw JSONB from bronze.salesforce_contract_rates into
--           readable columns for exploratory review before writing silver model.
--
-- layer:    bronze (read only — no data is created or modified)
-- schema:   bronze
-- source:   bronze.salesforce_contract_rates
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
    raw_data ->> 'Id'                                   as rate_id,
    raw_data ->> 'Name'                                 as rate_name,

    -- contract reference
    raw_data ->> 'Contract__c'                          as contract_id,

    -- rate details
    raw_data ->> 'Service_Type__c'                      as service_type,
    raw_data ->> 'Zone__c'                              as zone,
    (raw_data ->> 'Rate_Per_Mile__c')::numeric          as rate_per_mile,
    (raw_data ->> 'Base_Rate__c')::numeric              as base_rate,
    (raw_data ->> 'Minimum_Charge__c')::numeric         as minimum_charge,

    -- validity
    (raw_data ->> 'Effective_Date__c')::date            as effective_date,
    (raw_data ->> 'Expiry_Date__c')::date               as expiry_date,
    (raw_data ->> 'IsActive__c')::boolean               as is_active,

    -- raw data for reference
    raw_data

from bronze.salesforce_contract_rates

order by ingest_timestamp desc, bronze_row_id desc