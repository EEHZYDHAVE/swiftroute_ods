-- =============================================================================
-- analysis: explore_salesforce_accounts.sql
-- purpose:  Unpack raw JSONB from bronze.salesforce_accounts into readable
--           columns for exploratory review before writing the silver model.
--
-- layer:    bronze (read only, no data is created or modified)
-- schema:   bronze
-- source:   bronze.salesforce_accounts (loaded by loaders/load_salesforce.py)
--
-- usage:    Run via dbt Power User preview or psql session.
--           Not materialized, analysis files never create database objects.
-- =============================================================================

select
    -- metadata columns added by the loader
    id                                              as bronze_row_id,
    ingest_timestamp                                as bronze_ingest_timestamp,
    source_file                                     as bronze_source_file,

    -- core account identifiers
    raw_data ->> 'Id'                               as account_id,
    raw_data ->> 'Name'                             as account_name,
    raw_data ->> 'AccountNumber'                    as account_number,
    raw_data ->> 'Type'                             as account_type,
    raw_data ->> 'Industry'                         as industry,

    -- contact details
    raw_data ->> 'Phone'                            as phone,
    raw_data ->> 'Website'                          as website,

    -- address
    raw_data -> 'BillingAddress' ->> 'street'       as billing_street,
    raw_data -> 'BillingAddress' ->> 'city'         as billing_city,
    raw_data -> 'BillingAddress' ->> 'state'        as billing_state,
    raw_data -> 'BillingAddress' ->> 'country'      as billing_country,

    -- status
    raw_data ->> 'IsActive__c'                      as is_active,

    -- raw data for reference
    raw_data

from bronze.salesforce_accounts

order by ingest_timestamp desc, bronze_row_id desc