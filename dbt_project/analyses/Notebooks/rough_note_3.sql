SELECT
    *
FROM (
    SELECT
    -- metadata columns added by the loader
    id                                                  AS bronze_row_id,
    ingest_timestamp                                    AS bronze_ingest_timestamp,
    source_file                                         AS bronze_source_file,

    -- core contract identifiers
    raw_data ->> 'Id'                                   AS contract_id,

    -- account
    raw_data ->> 'AccountId'                            AS account_id,

    -- ownership
    raw_data ->> 'OwnerId'                              AS owner_id,

    -- contract dates
    (raw_data ->> 'StartDate')::date                    AS start_date,
    (raw_data ->> 'EndDate')::date                      AS end_date,
    (raw_data ->> 'SignedDate__c')::date                AS signed_date,

    -- lifecycle
    raw_data ->> 'Status'                               AS status,
    raw_data ->> 'Contract_Type__c'                     AS contract_type,
    (raw_data ->> 'Auto_Renewal__c')::boolean           AS auto_renewal,

    -- commercial terms
    (raw_data ->> 'ContractTerm')::int                  AS contract_term_months,
    (raw_data ->> 'Discount_Rate__c')::numeric          AS discount_rate,
    (raw_data ->> 'Net_Payment_Terms__c')::int          AS net_payment_terms_days,
    (raw_data ->> 'Termination_Notice_Days__c')::int    AS termination_notice_days,
    (raw_data ->> 'Committed_Monthly_Volume__c')::int   AS committed_monthly_volume,

    -- customer attributes
    raw_data ->> 'Account_Tier__c'                      AS account_tier,
    raw_data ->> 'Primary_City__c'                      AS primary_city,

    -- Salesforce timestamps
    (raw_data ->> 'CreatedDate')::timestamp             AS created_at,
    (raw_data ->> 'LastModifiedDate')::timestamp        AS last_modified_at,

    -- raw JSON
    raw_data

FROM bronze.salesforce_contracts
ORDER BY ingest_timestamp DESC, bronze_row_id DESC
) AS salesforce_contracts