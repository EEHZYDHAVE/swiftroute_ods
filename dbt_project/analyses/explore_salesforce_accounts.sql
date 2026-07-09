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


SELECT
    -- metadata columns added by the loader
    id                                              AS bronze_row_id,
    ingest_timestamp                                AS bronze_ingest_timestamp,
    source_file                                     AS bronze_source_file,

    -- core account identifiers
    raw_data ->> 'Id'                               AS account_id,
    raw_data ->> 'Name'                             AS account_name,
    raw_data ->> 'Type'                             AS account_type,
    raw_data ->> 'Industry'                         AS industry,

    -- SwiftRoute business attributes
    raw_data ->> 'SwiftRoute_Client_ID__c'          AS swiftroute_client_id,
    raw_data ->> 'Account_Tier__c'                  AS account_tier,
    raw_data ->> 'Primary_City__c'                  AS primary_city,
    raw_data ->> 'Contract_Type__c'                 AS contract_type,
    (raw_data ->> 'Discount_Rate__c')::numeric      AS discount_rate,
    (raw_data ->> 'Net_Payment_Terms__c')::int      AS net_payment_terms,
    (raw_data ->> 'Is_Fulfillment_Client__c')::boolean
                                                    AS is_fulfillment_client,
    (raw_data ->> 'Contracted_Monthly_Volume__c')::int
                                                    AS contracted_monthly_volume,

    -- owner
    raw_data ->> 'OwnerId'                          AS owner_id,
    raw_data -> 'Owner' ->> 'Name'                  AS owner_name,
    raw_data -> 'Owner' ->> 'Email'                 AS owner_email,

    -- contact
    raw_data ->> 'Phone'                            AS phone,
    raw_data ->> 'Website'                          AS website,

    -- billing address
    raw_data -> 'BillingAddress' ->> 'street'       AS billing_street,
    raw_data -> 'BillingAddress' ->> 'city'         AS billing_city,
    raw_data -> 'BillingAddress' ->> 'state'        AS billing_state,
    raw_data -> 'BillingAddress' ->> 'stateCode'    AS billing_state_code,
    raw_data -> 'BillingAddress' ->> 'postalCode'   AS billing_postal_code,
    raw_data -> 'BillingAddress' ->> 'country'      AS billing_country,
    raw_data -> 'BillingAddress' ->> 'countryCode'  AS billing_country_code,

    -- company profile
    (raw_data ->> 'AnnualRevenue')::numeric         AS annual_revenue,
    (raw_data ->> 'NumberOfEmployees')::int         AS number_of_employees,

    -- timestamps
    (raw_data ->> 'CreatedDate')::timestamp         AS created_at,
    (raw_data ->> 'LastModifiedDate')::timestamp    AS last_modified_at,
    (raw_data ->> 'LastActivityDate')::date         AS last_activity_date,

    -- raw JSON
    raw_data

FROM bronze.salesforce_accounts

ORDER BY ingest_timestamp DESC, bronze_row_id DESC;

RAW DATA:
{
  "Id": "001bk34UPW52P6YtCB",
  "Name": "Hurley, Contreras and Dunlap",
  "Type": "Customer",
  "Owner": {
    "Name": "Laura Weeks",
    "Email": "qfisher@example.com",
    "attributes": {
      "url": "/services/data/v58.0/sobjects/User/005WIzbZN5W8I4oLun",
      "type": "User"
    }
  },
  "Phone": "839.993.9337x4647",
  "OwnerId": "005WIzbZN5W8I4oLun",
  "Website": "https://www.swanson.com",
  "Industry": "Manufacturing",
  "attributes": {
    "url": "/services/data/v58.0/sobjects/Account/001bk34UPW52P6YtCB",
    "type": "Account"
  },
  "CreatedDate": "2023-12-26T00:00:00.000+0000",
  "AnnualRevenue": 22929,
  "BillingAddress": {
    "city": "Whiteberg",
    "state": "Connecticut",
    "street": "576 Troy Fork",
    "country": "United States",
    "stateCode": "CO",
    "postalCode": "22423",
    "countryCode": "US"
  },
  "Account_Tier__c": "standard",
  "Primary_City__c": "denver",
  "Contract_Type__c": "Variable Rate",
  "Discount_Rate__c": 0.06,
  "LastActivityDate": "2025-05-08",
  "LastModifiedDate": "2025-05-08T00:00:00.000+0000",
  "NumberOfEmployees": 193,
  "Net_Payment_Terms__c": 30,
  "SwiftRoute_Client_ID__c": "client_094",
  "Is_Fulfillment_Client__c": false,
  "Contracted_Monthly_Volume__c": 146
}