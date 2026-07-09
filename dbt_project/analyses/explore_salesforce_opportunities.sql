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

SELECT
    -- metadata columns added by the loader
    id                                              AS bronze_row_id,
    ingest_timestamp                                AS bronze_ingest_timestamp,
    source_file                                     AS bronze_source_file,

    -- core identifiers
    raw_data ->> 'Id'                               AS opportunity_id,
    raw_data ->> 'Name'                             AS opportunity_name,

    -- account
    raw_data ->> 'AccountId'                        AS account_id,
    raw_data -> 'Account' ->> 'Name'                AS account_name,
    raw_data -> 'Account' ->> 'SwiftRoute_Client_ID__c'
                                                    AS swiftroute_client_id,

    -- ownership
    raw_data ->> 'OwnerId'                          AS owner_id,

    -- opportunity details
    raw_data ->> 'StageName'                        AS stage,
    raw_data ->> 'Type'                             AS opportunity_type,
    raw_data ->> 'LeadSource'                       AS lead_source,

    -- commercial attributes
    raw_data ->> 'Account_Tier__c'                  AS account_tier,
    raw_data ->> 'Primary_City__c'                  AS primary_city,
    raw_data ->> 'Contract_Type__c'                 AS contract_type,

    -- financials
    (raw_data ->> 'Amount')::numeric                AS amount,
    (raw_data ->> 'Probability')::numeric           AS probability,
    (raw_data ->> 'ExpectedRevenue')::numeric       AS expected_revenue,

    -- dates
    (raw_data ->> 'CloseDate')::date                AS close_date,
    (raw_data ->> 'CreatedDate')::timestamp         AS created_at,
    (raw_data ->> 'LastActivityDate')::date         AS last_activity_date,

    -- raw JSON
    raw_data

FROM bronze.salesforce_opportunities

ORDER BY ingest_timestamp DESC, bronze_row_id DESC;


RAW DATA:
{
  "Id": "006dtT3L9brSoLAjVO",
  "Name": "Hurley, Contreras and Dunlap — Contract Renewal 2025",
  "Type": "Renewal",
  "Amount": 246456.05,
  "Account": {
    "Name": "Hurley, Contreras and Dunlap",
    "attributes": {
      "url": "/services/data/v58.0/sobjects/Account/001bk34UPW52P6YtCB",
      "type": "Account"
    },
    "SwiftRoute_Client_ID__c": "client_094"
  },
  "OwnerId": "005WIzbZN5W8I4oLun",
  "AccountId": "001bk34UPW52P6YtCB",
  "CloseDate": "2025-06-25",
  "StageName": "Closed Lost",
  "LeadSource": "Web",
  "attributes": {
    "url": "/services/data/v58.0/sobjects/Opportunity/006dtT3L9brSoLAjVO",
    "type": "Opportunity"
  },
  "CreatedDate": "2025-02-21T00:00:00.000+0000",
  "Probability": 0,
  "Account_Tier__c": "standard",
  "Primary_City__c": "denver",
  "Contract_Type__c": "Variable Rate",
  "LastActivityDate": "2025-06-28"
}