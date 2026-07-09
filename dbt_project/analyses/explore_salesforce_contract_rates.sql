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

RAW DATA:
{
  "Id": "a0ByKoNBJoCCiQxQEK",
  "Unit__c": "per_delivery",
  "Account__c": "00171NdWntubUCnfTS",
  "Zone_ID__c": "zone_slc_4",
  "attributes": {
    "url": "/services/data/v58.0/sobjects/Contract_Rate__c/a0ByKoNBJoCCiQxQEK",
    "type": "Contract_Rate__c"
  },
  "Contract__c": "800HPTSfcjmaPN1BRt",
  "CreatedDate": "2025-03-10T00:00:00.000+0000",
  "Net_Rate__c": 12.51,
  "Base_Rate__c": 14.55,
  "Zone_Name__c": "Zone Slc 4",
  "Service_Type__c": "same_day",
  "Discount_Rate__c": 0.14,
  "Effective_Date__c": "2025-04-03",
  "SwiftRoute_Client_ID__c": "client_093"
}