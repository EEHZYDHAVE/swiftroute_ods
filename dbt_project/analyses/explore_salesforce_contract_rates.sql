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

SELECT
    -- metadata columns added by the loader
    id                                              AS bronze_row_id,
    ingest_timestamp                                AS bronze_ingest_timestamp,
    source_file                                     AS bronze_source_file,

    -- core identifiers
    raw_data ->> 'Id'                               AS rate_id,

    -- relationships
    raw_data ->> 'Contract__c'                      AS contract_id,
    raw_data ->> 'Account__c'                       AS account_id,
    raw_data ->> 'SwiftRoute_Client_ID__c'          AS swiftroute_client_id,

    -- service details
    raw_data ->> 'Service_Type__c'                  AS service_type,
    raw_data ->> 'Unit__c'                          AS unit,

    -- zone
    raw_data ->> 'Zone_ID__c'                       AS zone_id,
    raw_data ->> 'Zone_Name__c'                     AS zone_name,

    -- pricing
    (raw_data ->> 'Base_Rate__c')::numeric          AS base_rate,
    (raw_data ->> 'Net_Rate__c')::numeric           AS net_rate,
    (raw_data ->> 'Discount_Rate__c')::numeric      AS discount_rate,

    -- validity
    (raw_data ->> 'Effective_Date__c')::date        AS effective_date,

    -- metadata from Salesforce
    (raw_data ->> 'CreatedDate')::timestamp         AS created_at,

    -- raw JSON
    raw_data

FROM bronze.salesforce_contract_rates

ORDER BY ingest_timestamp DESC, bronze_row_id DESC;