SELECT 
    *
FROM(
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

ORDER BY ingest_timestamp DESC, bronze_row_id DESC
) AS salesforce_opportunities