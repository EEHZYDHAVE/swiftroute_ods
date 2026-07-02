-- =============================================================================
-- analysis: explore_salesforce_opportunities.sql
-- purpose:  Unpack raw JSONB from bronze.salesforce_opportunities into
--           readable columns for exploratory review before writing silver model.
--
-- layer:    bronze (read only — no data is created or modified)
-- schema:   bronze
-- source:   bronze.salesforce_opportunities
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
    raw_data ->> 'Id'                                   as opportunity_id,
    raw_data ->> 'Name'                                 as opportunity_name,

    -- account reference
    raw_data ->> 'AccountId'                            as account_id,

    -- opportunity details
    raw_data ->> 'StageName'                            as stage,
    raw_data ->> 'Type'                                 as opportunity_type,
    raw_data ->> 'LeadSource'                           as lead_source,

    -- financials
    (raw_data ->> 'Amount')::numeric                    as amount,
    (raw_data ->> 'Probability')::numeric               as probability,
    (raw_data ->> 'ExpectedRevenue')::numeric           as expected_revenue,

    -- dates
    (raw_data ->> 'CloseDate')::date                    as close_date,
    (raw_data ->> 'CreatedDate')::timestamp             as created_at,

    -- raw data for reference
    raw_data

from bronze.salesforce_opportunities

order by ingest_timestamp desc, bronze_row_id desc