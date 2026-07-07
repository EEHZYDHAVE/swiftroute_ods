

SELECT
    *
from (
    SELECT
    -- metadata columns added by the loader
    id                                              AS bronze_row_id,
    ingest_timestamp                                AS bronze_ingest_timestamp,
    source_file                                     AS bronze_source_file,

    -- core account identifiers
    raw_data ->> 'Id'                               AS account_id,
    raw_data ->> 'Name'                             AS account_name,
    raw_data ->> 'AccountNumber'                    AS account_number,
    raw_data ->> 'Type'                             AS account_type,
    raw_data ->> 'Industry'                         AS industry,
    raw_data ->> 'Account_Tier__c'                  AS account_tier,
    raw_data ->> 'Primary_City__c'                  AS primary_city,
    raw_data ->> 'Contract_Type__c'                 AS contract_type,
    (raw_data ->> 'Discount_Rate__c')::numeric      AS discount_rate,
    (raw_data ->> 'Net_Payment_Terms__c')::int      AS net_payment_terms,
    raw_data ->> 'SwiftRoute_Client_ID__c'          AS swiftroute_client_id,
    (raw_data ->> 'Is_Fulfillment_Client__c')::boolean AS is_fulfillment_client,
    (raw_data ->> 'Contracted_Monthly_Volume__c')::int AS contracted_monthly_volume,

    -- owner details
    raw_data ->> 'OwnerId'                          AS owner_id,
    raw_data -> 'Owner' ->> 'Name'                  AS owner_name,
    raw_data -> 'Owner' ->> 'Email'                 AS owner_email,

    -- contact details
    raw_data ->> 'Phone'                            AS phone,
    raw_data ->> 'Website'                          AS website,

    -- address
    raw_data -> 'BillingAddress' ->> 'street'       AS billing_street,
    raw_data -> 'BillingAddress' ->> 'city'         AS billing_city,
    raw_data -> 'BillingAddress' ->> 'state'        AS billing_state,
    raw_data -> 'BillingAddress' ->> 'stateCode'    AS billing_state_code,
    raw_data -> 'BillingAddress' ->> 'postalCode'   AS billing_postal_code,
    raw_data -> 'BillingAddress' ->> 'country'      AS billing_country,
    raw_data -> 'BillingAddress' ->> 'countryCode'  AS billing_country_code,

    -- financials
    (raw_data ->> 'AnnualRevenue')::numeric         AS annual_revenue,
    (raw_data ->> 'NumberOfEmployees')::int         AS number_of_employees,

    -- dates
    (raw_data ->> 'CreatedDate')::timestamp         AS created_date,
    (raw_data ->> 'LastActivityDate')::date         AS last_activity_date,
    (raw_data ->> 'LastModifiedDate')::timestamp    AS last_modified_date,

    -- status
    raw_data ->> 'IsActive__c'                      AS is_active,

    -- raw data for reference
    raw_data

FROM bronze.salesforce_accounts
ORDER BY ingest_timestamp DESC, bronze_row_id DESC
) as salesforce_accounts